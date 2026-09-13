defmodule TestNervesHub.Load.Cluster do
  @moduledoc """
  The `nerves_hub_web` side of a load run: one API node plus the
  device-role nodes devices connect to.

  The API node is the same single node the end-to-end tests use — the
  `all` role in `dev`, under the default `TestNervesHub.Server` name — so
  the fixture helpers work unchanged. If one is already running (the
  ExUnit `test_helper` starts it) it is reused.

  Device nodes get consecutive port blocks above the API node's and share
  the API node's distribution cookie, which is what lets `libcluster`'s
  Postgres strategy join them into one cluster: exactly the topology a
  deployment runs, web nodes and device nodes over one database.
  """

  require Logger

  alias TestNervesHub.{Config, Server}
  alias TestNervesHub.Load.Scenario

  @type t :: %{
          api: GenServer.name(),
          device_nodes: [GenServer.name()],
          nodes: [GenServer.name()],
          cookie: String.t()
        }

  # Ports per device node: web, device, status.
  @port_stride 10

  @doc "Start (or adopt) the API node and start the device nodes."
  @spec start(Scenario.t()) :: t()
  def start(%Scenario{} = scenario) do
    {api, started_api?} = ensure_api_node("tnh_load_#{:erlang.unique_integer([:positive])}")
    %{node: api_node} = Server.info(api)
    # An adopted node has a cookie of its own; the device nodes take that.
    cookie = Atom.to_string(cookie_of(api))
    Logger.info("load cluster: API node #{api_node}")

    device_nodes =
      if scenario.device_nodes > 0 do
        if scenario.device_node_env == "prod", do: prepare_prod_build!()

        for i <- 1..scenario.device_nodes do
          start_device_node(i, scenario, cookie)
        end
      else
        []
      end

    device_nodes
    |> Task.async_stream(&(:ok = Server.await_ready(&1)),
      timeout: :timer.minutes(5),
      ordered: false
    )
    |> Stream.run()

    for name <- device_nodes do
      %{node: node, device_port: port} = Server.info(name)
      Logger.info("load cluster: device node #{node} on :#{port}")
    end

    wait_for_cluster!([api | device_nodes])

    %{
      api: api,
      device_nodes: device_nodes,
      nodes: [api | device_nodes],
      cookie: cookie,
      started_api?: started_api?
    }
  end

  @doc "Stop every node this module started (an adopted API node is left alone)."
  @spec stop(t()) :: :ok
  def stop(%{device_nodes: device_nodes} = cluster) do
    Enum.each(device_nodes, &safe_stop/1)
    if cluster[:started_api?], do: safe_stop(cluster.api)
    :ok
  end

  @doc "The `wss://host:port` device endpoint URL of a node."
  @spec device_url(GenServer.name()) :: String.t()
  def device_url(name) do
    %{device_port: port} = Server.info(name)
    "wss://#{Server.host_address()}:#{port}"
  end

  defp ensure_api_node(cookie) do
    case Process.whereis(Server) do
      nil ->
        {:ok, _} = Server.start_link(cookie: cookie)
        :ok = Server.await_ready()
        {Server, true}

      _pid ->
        {Server, false}
    end
  end

  defp cookie_of(name) do
    {_node, cookie} = GenServer.call(name, :node_and_cookie)
    cookie
  end

  defp start_device_node(i, scenario, cookie) do
    name = :"tnh_load_device_node_#{i}"
    web_port = Config.web_port() + @port_stride * i

    env = [
      {"FEATURES_HEALTH_INTERVAL_MINUTES", to_string(scenario.health_interval_minutes)},
      {"FEATURES_GEO_INTERVAL_MINUTES", "0"}
    ]

    {:ok, _} =
      Server.start_link(
        name: name,
        role: "device",
        mix_env: scenario.device_node_env,
        web_port: web_port,
        device_port: web_port + 1,
        status_port: web_port + 2,
        migrate?: false,
        prepare?: false,
        cookie: cookie,
        env: env
      )

    name
  end

  # Compiling prod inside each node's start would race; do it once, here.
  defp prepare_prod_build! do
    web_path = Config.nerves_hub_web_path()
    Logger.info("load cluster: compiling #{web_path} for MIX_ENV=prod")

    for task <- [["deps.get"], ["compile"]] do
      {out, code} = TestNervesHub.MixCmd.run(task, cd: web_path, env: [{"MIX_ENV", "prod"}])
      if code != 0, do: raise("MIX_ENV=prod mix #{Enum.join(task, " ")} failed:\n#{out}")
    end

    :ok
  end

  # libcluster's Postgres strategy polls; give the nodes a moment to see
  # each other before devices arrive, or the first joins land on a node
  # that cannot yet reach the orchestrators.
  defp wait_for_cluster!(names) do
    expected = length(names) - 1
    deadline = System.monotonic_time(:millisecond) + :timer.minutes(2)

    Enum.each(names, fn name ->
      wait_until(deadline, fn ->
        length(Server.rpc(name, Node, :list, [])) >= expected
      end) || raise("#{inspect(name)} never saw the rest of the cluster")
    end)
  end

  defp wait_until(deadline, fun) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(1_000) && wait_until(deadline, fun)
    end
  end

  defp safe_stop(name) do
    Server.stop(name)
  catch
    :exit, _ -> :ok
  end
end
