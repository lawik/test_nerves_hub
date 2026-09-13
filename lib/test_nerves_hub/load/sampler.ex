defmodule TestNervesHub.Load.Sampler do
  @moduledoc """
  Takes a measurement of every node in a load run on a timer.

  Per `nerves_hub_web` node: RSS from `/proc`, `:erlang.memory/0`,
  process and port counts, and the number of channel processes (one per
  joined topic, so a device with extensions is two). Per device host:
  the same memory figures plus how many of its devices report connected.
  Plus, from the database, how many of the product's devices NervesHub
  itself counts as online.

  Samples are appended to a JSONL file as they are taken, so a run that
  dies mid-way still leaves its data behind.
  """

  use GenServer

  alias TestNervesHub.Load.DeviceHost
  alias TestNervesHub.Server

  defstruct [:cluster, :hosts, :product_id, :every_ms, :path, :timer, samples: [], marks: []]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Take a sample now, tagged with `phase`, and return it."
  @spec sample(GenServer.server(), atom()) :: map()
  def sample(server \\ __MODULE__, phase),
    do: GenServer.call(server, {:sample, phase}, :timer.minutes(2))

  @doc "Change the phase tag applied to timer samples from now on."
  @spec mark(GenServer.server(), atom()) :: :ok
  def mark(server \\ __MODULE__, phase), do: GenServer.call(server, {:mark, phase})

  @doc "All samples so far, oldest first."
  @spec samples(GenServer.server()) :: [map()]
  def samples(server \\ __MODULE__), do: GenServer.call(server, :samples, :timer.minutes(1))

  @doc """
  A closer look at a server node for the report: the ten processes with
  the most memory and, through `recon_alloc`, how much of what the
  allocators hold is actually in use.
  """
  @spec details(GenServer.name()) :: map()
  def details(node_name) do
    Server.eval(node_name, """
    top =
      for {pid, mem, info} <- :recon.proc_count(:memory, 10) do
        %{pid: inspect(pid), memory: mem, info: inspect(info, limit: 5)}
      end

    %{
      top_processes: top,
      alloc_allocated: :recon_alloc.memory(:allocated),
      alloc_used: :recon_alloc.memory(:usage),
      binary_leak_top: (for {pid, delta, _} <- :recon.bin_leak(5), do: %{pid: inspect(pid), delta: delta})
    }
    """)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      cluster: Keyword.fetch!(opts, :cluster),
      hosts: Keyword.get(opts, :hosts, []),
      product_id: Keyword.fetch!(opts, :product_id),
      every_ms: Keyword.get(opts, :every_ms, 5_000),
      path: Keyword.fetch!(opts, :path),
      marks: [:setup]
    }

    File.mkdir_p!(Path.dirname(state.path))
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call({:sample, phase}, _from, state) do
    sample = take(state, phase)
    {:reply, sample, record(state, sample)}
  end

  def handle_call({:mark, phase}, _from, state),
    do: {:reply, :ok, %{state | marks: [phase | state.marks]}}

  def handle_call(:samples, _from, state), do: {:reply, Enum.reverse(state.samples), state}

  @impl true
  def handle_info(:tick, state) do
    sample = take(state, hd(state.marks))
    {:noreply, state |> record(sample) |> schedule()}
  end

  defp schedule(state), do: %{state | timer: Process.send_after(self(), :tick, state.every_ms)}

  defp record(state, sample) do
    File.write!(state.path, Jason.encode!(sample) <> "\n", [:append])
    %{state | samples: [sample | state.samples]}
  end

  defp take(state, phase) do
    servers =
      for name <- state.cluster.nodes, into: %{} do
        info = Server.info(name)

        {Atom.to_string(info.node),
         Map.merge(server_sample(name), %{rss_kb: rss_kb(info.os_pid), role: info.role})}
      end

    hosts =
      for host <- state.hosts, into: %{} do
        info = DeviceHost.info(host)
        {Atom.to_string(info.node), Map.merge(host_sample(host), %{rss_kb: rss_kb(info.os_pid)})}
      end

    online =
      Server.rpc(state.cluster.api, NervesHub.Devices, :online_count, [%{id: state.product_id}])

    %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      t: System.monotonic_time(:millisecond),
      phase: phase,
      servers: servers,
      hosts: hosts,
      online: online
    }
  end

  defp server_sample(name) do
    Server.eval(name, """
    procs = Process.list()

    # What kinds of process there are, by the module each was started with.
    # Channels and socket transports are the ones that grow with devices.
    histogram =
      procs
      |> Enum.map(fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            case dict[:"$initial_call"] do
              {mod, _, _} -> inspect(mod)
              _ -> "other"
            end

          _ ->
            "dead"
        end
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_, n} -> n >= 3 end)
      |> Map.new()

    # Channel processes carry their channel module as initial call; the
    # websocket connections themselves are Bandit's delegating handlers.
    channels =
      histogram
      |> Enum.filter(fn {mod, _} -> String.ends_with?(mod, "Channel") end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    connections = Map.get(histogram, "Bandit.DelegatingHandler", 0)

    %{
      memory: Map.new(:erlang.memory(), fn {k, v} -> {Atom.to_string(k), v} end),
      process_count: length(procs),
      port_count: :erlang.system_info(:port_count),
      channels: channels,
      connections: connections,
      processes_by_module: histogram,
      run_queue: :erlang.statistics(:run_queue)
    }
    """)
  rescue
    error -> %{error: inspect(error)}
  end

  defp host_sample(host) do
    Map.merge(
      DeviceHost.rpc(host, Elixir.DeviceHost, :memory, []),
      DeviceHost.rpc(host, Elixir.DeviceHost, :status, [], :timer.minutes(1))
    )
  rescue
    error -> %{error: inspect(error)}
  end

  @doc false
  def rss_kb(nil), do: nil

  def rss_kb(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, status} ->
        case Regex.run(~r/VmRSS:\s+(\d+) kB/, status) do
          [_, kb] -> String.to_integer(kb)
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
