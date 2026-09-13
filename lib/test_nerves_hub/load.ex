defmodule TestNervesHub.Load do
  @moduledoc """
  Connect a fleet of virtual devices to a `nerves_hub_web` cluster, hold,
  disconnect, and measure what it cost.

  A run (`run/1`) goes:

    1. **cluster** — the API node plus the scenario's device-role nodes
       (`TestNervesHub.Load.Cluster`), and the device host nodes
       (`TestNervesHub.Load.DeviceHost`).
    2. **fixtures** — a fresh org/product with a shared secret, a fake
       firmware uploaded through the CLI API, and an active deployment
       group so devices are attached to one as they join.
    3. **baseline** — a sample with everything up and nothing connected.
    4. **ramp** — devices are started across the hosts at the configured
       rate, round-robin over the device nodes, until NervesHub and the
       hosts agree they are all connected.
    5. **hold** — the fleet sits connected for `hold_seconds` while the
       sampler records; health reports and heartbeats flow as they would
       in a fleet.
    6. **settle** — devices are stopped, the nodes get `settle_seconds` to
       release memory, and a last sample is taken. Memory that does not
       come back is the number to watch.

  Output lands in `<work>/load/<run id>/`: `samples.jsonl`, `summary.json`,
  `report.md`, and the nodes' logs. `TestNervesHub.Load.Report.compare/2`
  puts two summaries side by side, which is how a branch is checked
  against `main`.
  """

  require Logger

  alias TestNervesHub.{Config, Deploy, Org, Server}
  alias TestNervesHub.Load.{Cluster, DeviceHost, Firmware, Report, Sampler, Scenario}

  @type result :: %{summary: map(), dir: Path.t(), samples: [map()]}

  @doc "Run a scenario end to end. Raises if the fleet never connects."
  @spec run(Scenario.t()) :: result()
  def run(%Scenario{} = scenario) do
    run_id = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    dir = Path.join([Config.work_dir(), "load", run_id])
    File.mkdir_p!(dir)
    Logger.info("load #{run_id}: #{inspect(scenario)}")

    cluster = Cluster.start(scenario)
    hosts = start_hosts(scenario, cluster, dir)

    try do
      do_run(scenario, cluster, hosts, run_id, dir)
    after
      Enum.each(hosts, &safe(fn -> DeviceHost.stop(&1) end))
      Cluster.stop(cluster)
    end
  end

  defp do_run(scenario, cluster, hosts, run_id, dir) do
    fixtures = Org.setup_module("load-#{run_id}")
    {key, secret} = Org.create_shared_secret_auth(fixtures.product)

    {fw, fw_params} =
      Firmware.build(%{
        product: fixtures.product.name,
        version: "1.0.0",
        payload_bytes: scenario.payload_bytes
      })

    {:ok, %{uuid: fw_uuid}} = Deploy.publish_firmware(fixtures, fw, fixtures.org_key)

    {:ok, _} =
      Deploy.create_and_activate_deployment(fixtures, "load-#{run_id}", fw_uuid,
        tags: [],
        version: ""
      )

    fw_params = Map.put(fw_params, "nerves_fw_uuid", fw_uuid)
    Logger.info("load #{run_id}: firmware #{fw_uuid} published, deployment active")

    {:ok, sampler} =
      Sampler.start_link(
        cluster: cluster,
        hosts: hosts,
        product_id: fixtures.product.id,
        every_ms: scenario.sample_every_ms,
        path: Path.join(dir, "samples.jsonl")
      )

    _ = Sampler.sample(sampler, :baseline)

    specs = specs(scenario, cluster, hosts, fixtures, key, secret, fw_params, run_id)
    Sampler.mark(sampler, :ramp)
    started_at = System.monotonic_time(:millisecond)

    per_host = max(1, div(scenario.ramp_per_second, max(1, length(hosts))))

    for {host, host_specs} <- specs do
      :ok =
        DeviceHost.rpc(host, Elixir.DeviceHost, :start_devices, [
          host_specs,
          [per_second: per_host]
        ])
    end

    :ok = wait_for_fleet!(hosts, cluster, fixtures, scenario)
    connect_seconds = div(System.monotonic_time(:millisecond) - started_at, 1000)

    Logger.info(
      "load #{run_id}: all #{scenario.devices} devices connected in #{connect_seconds}s"
    )

    Sampler.mark(sampler, :hold)
    Process.sleep(:timer.seconds(scenario.hold_seconds))
    _ = Sampler.sample(sampler, :hold)

    details =
      for name <- cluster.nodes,
          into: %{},
          do: {inspect(name), safe(fn -> Sampler.details(name) end)}

    Sampler.mark(sampler, :disconnect)

    for host <- hosts,
        do: DeviceHost.rpc(host, Elixir.DeviceHost, :stop_devices, [:all], :timer.minutes(2))

    Process.sleep(:timer.seconds(scenario.settle_seconds))
    _ = Sampler.sample(sampler, :settled)

    samples = Sampler.samples(sampler)
    GenServer.stop(sampler)

    meta =
      scenario
      |> Map.from_struct()
      |> Map.merge(%{
        run_id: run_id,
        web_path: Config.nerves_hub_web_path(),
        web_ref: git_ref(Config.nerves_hub_web_path()),
        connect_seconds: connect_seconds,
        details: details,
        product: fixtures.product.name
      })

    summary = Report.summarise(samples, meta)
    File.write!(Path.join(dir, "summary.json"), Jason.encode!(summary, pretty: true))
    File.write!(Path.join(dir, "report.md"), Report.to_markdown(summary))
    Logger.info("load #{run_id}: report in #{dir}")

    %{summary: summary, dir: dir, samples: samples}
  end

  defp start_hosts(scenario, cluster, dir) do
    DeviceHost.prepare!()

    hosts =
      for i <- 1..scenario.device_hosts do
        {:ok, _} =
          DeviceHost.start_link(
            index: i,
            cookie: cluster.cookie,
            log: Path.join(dir, "device_host_#{i}.log")
          )

        DeviceHost.name(i)
      end

    Enum.each(hosts, &(:ok = DeviceHost.await_ready(&1)))
    hosts
  end

  # Device i goes to host i mod hosts and dials device node i mod nodes
  # (or the API node when there are none): a balancer's round-robin.
  defp specs(scenario, cluster, hosts, fixtures, key, secret, fw_params, run_id) do
    endpoints =
      case cluster.device_nodes do
        [] -> [Cluster.device_url(cluster.api)]
        nodes -> Enum.map(nodes, &Cluster.device_url/1)
      end

    cacerts = Server.ca_pem()

    for i <- 0..(scenario.devices - 1) do
      spec = %{
        index: i,
        identifier: "vd-#{run_id}-#{String.pad_leading(Integer.to_string(i), 5, "0")}",
        product_key: key,
        product_secret: secret,
        host: Enum.at(endpoints, rem(i, length(endpoints))),
        sni: Server.device_cert_hostname(),
        cacerts: cacerts,
        firmware: fw_params,
        serializer: scenario.serializer,
        compress: scenario.compress
      }

      {Enum.at(hosts, rem(i, length(hosts))), spec}
    end
    |> Enum.group_by(fn {host, _} -> host end, fn {_, spec} -> spec end)
    |> then(fn by_host -> for host <- hosts, do: {host, Map.get(by_host, host, [])} end)
    |> tap(fn _ -> _ = fixtures end)
  end

  defp wait_for_fleet!(hosts, cluster, fixtures, scenario) do
    deadline = System.monotonic_time(:millisecond) + :timer.seconds(scenario.connect_timeout)
    do_wait(hosts, cluster, fixtures, scenario.devices, deadline, 0)
  end

  defp do_wait(hosts, cluster, fixtures, devices, deadline, last_log) do
    statuses =
      for host <- hosts,
          do: DeviceHost.rpc(host, Elixir.DeviceHost, :status, [], :timer.minutes(1))

    connected = statuses |> Enum.map(& &1.connected) |> Enum.sum()
    failed = statuses |> Enum.flat_map(& &1.failed)

    online =
      Server.rpc(cluster.api, NervesHub.Devices, :online_count, [%{id: fixtures.product.id}])

    now = System.monotonic_time(:millisecond)

    cond do
      failed != [] ->
        raise "devices failed to start: #{inspect(Enum.take(failed, 5))}"

      connected >= devices and online >= devices ->
        :ok

      now > deadline ->
        raise "fleet never fully connected: #{connected}/#{devices} sockets joined, NervesHub sees #{online}"

      true ->
        last_log =
          if now - last_log > 5_000 do
            Logger.info("load: #{connected}/#{devices} joined, NervesHub online count #{online}")
            now
          else
            last_log
          end

        Process.sleep(1_000)
        do_wait(hosts, cluster, fixtures, devices, deadline, last_log)
    end
  end

  defp git_ref(path) do
    case System.cmd("git", ["-C", path, "describe", "--always", "--dirty"],
           stderr_to_stdout: true
         ) do
      {ref, 0} -> String.trim(ref)
      _ -> "unknown"
    end
  end

  defp safe(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
