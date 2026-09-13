defmodule DeviceHost.Fleet do
  @moduledoc """
  Starts, stops and counts the virtual devices on this node.

  Devices are started at a configurable rate rather than all at once: a
  thousand TLS handshakes in the same millisecond is a test of the host's
  CPU, not of NervesHub, and it is not how a fleet reconnects after a
  deploy either — devices back off with jitter.
  """

  use GenServer

  alias DeviceHost.Device

  require Logger

  @tick_ms 100

  defstruct pending: :queue.new(), per_tick: 1, timer: nil, started: 0, failed: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue `specs` (see `DeviceHost.Device`) to be started.

  Options:
    * `:per_second` — start rate, default 50. Starts are spread over
      100ms ticks, so 50/s is 5 per tick.

  Returns immediately; poll `status/0` for progress.
  """
  @spec start_devices([Device.spec()], keyword()) :: :ok
  def start_devices(specs, opts \\ []) when is_list(specs) do
    GenServer.call(__MODULE__, {:start_devices, specs, opts})
  end

  @doc "Stop devices by index, or `:all`."
  @spec stop_devices([non_neg_integer()] | :all) :: :ok
  def stop_devices(which) do
    GenServer.call(__MODULE__, {:stop_devices, which}, :timer.minutes(2))
  end

  @doc """
  How the fleet is doing: how many devices are queued, running, and
  connected (joined the device channel), and any that failed to start.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status, :timer.minutes(1))
  end

  @doc """
  Indexes of the devices currently running on this node.

  Read from `NervesHubLink.Registry`: every device's supervisor is
  registered there under `{NervesHubLink.Supervisor, index}`, which is
  more direct than the fleet supervisor's children (a `DynamicSupervisor`
  reports every child id as `:undefined`).
  """
  @spec running() :: [non_neg_integer()]
  def running do
    NervesHubLink.Instance.registry()
    |> Registry.select([{{{NervesHubLink.Supervisor, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:start_devices, specs, opts}, _from, state) do
    per_second = Keyword.get(opts, :per_second, 50)
    per_tick = max(1, div(per_second, div(1000, @tick_ms)))

    pending = Enum.reduce(specs, state.pending, &:queue.in/2)
    state = %{state | pending: pending, per_tick: per_tick}
    {:reply, :ok, schedule_tick(state)}
  end

  def handle_call({:stop_devices, which}, _from, state) do
    indexes = if which == :all, do: running(), else: which

    for index <- indexes,
        pid = GenServer.whereis(Device.supervisor_name(index)),
        is_pid(pid) do
      _ = DynamicSupervisor.terminate_child(DeviceHost.FleetSupervisor, pid)
    end

    pending = if which == :all, do: :queue.new(), else: state.pending
    {:reply, :ok, %{state | pending: pending}}
  end

  def handle_call(:status, _from, state) do
    indexes = running()

    connected =
      indexes
      |> Task.async_stream(&connected?/1, max_concurrency: 64, timeout: 10_000, on_timeout: :kill_task)
      |> Enum.count(fn
        {:ok, true} -> true
        _ -> false
      end)

    reply = %{
      queued: :queue.len(state.pending),
      running: length(indexes),
      connected: connected,
      started: state.started,
      failed: Enum.reverse(state.failed)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {batch, pending} = take(state.pending, state.per_tick, [])

    state =
      Enum.reduce(batch, %{state | pending: pending, timer: nil}, fn spec, acc ->
        case DynamicSupervisor.start_child(DeviceHost.FleetSupervisor, {Device, spec}) do
          {:ok, _pid} ->
            %{acc | started: acc.started + 1}

          {:error, {:already_started, _}} ->
            acc

          {:error, reason} ->
            Logger.warning("device #{spec.index} failed to start: #{inspect(reason)}")
            %{acc | failed: [{spec.index, inspect(reason)} | acc.failed]}
        end
      end)

    {:noreply, schedule_tick(state)}
  end

  defp schedule_tick(%{timer: nil} = state) do
    if :queue.is_empty(state.pending) do
      state
    else
      %{state | timer: Process.send_after(self(), :tick, @tick_ms)}
    end
  end

  defp schedule_tick(state), do: state

  defp take(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp take(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> take(rest, n - 1, [item | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end

  defp connected?(index) do
    NervesHubLink.connected?(Device.socket_name(index))
  catch
    :exit, _ -> false
  end
end
