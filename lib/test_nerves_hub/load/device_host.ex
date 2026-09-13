defmodule TestNervesHub.Load.DeviceHost do
  @moduledoc """
  Runs one `device_host` node (see `device_host/` in this repo) as an OS
  process and talks to it over Erlang distribution.

  The project is compiled once per run through `prepare!/0`; each node is
  then `mix run --no-halt` with a distinct node name. `NERVES_HUB_LINK_PATH`
  in the runner's environment is passed through so a local checkout of the
  client can be used instead of the pinned fork branch.
  """

  use GenServer
  require Logger

  alias TestNervesHub.{Config, MixCmd}

  @startup_timeout :timer.minutes(2)

  defstruct [:index, :port, :node, :cookie, :log, :os_pid, :ready?]

  @doc "Path of the device_host mix project."
  @spec project_dir() :: Path.t()
  def project_dir do
    System.get_env("TEST_NERVES_HUB_DEVICE_HOST_DIR") ||
      Path.expand("../../../device_host", __DIR__)
  end

  @doc "Fetch deps and compile the device host project."
  @spec prepare!() :: :ok
  def prepare! do
    dir = project_dir()
    Logger.info("device host: preparing #{dir}")

    for task <- [["deps.get"], ["compile"]] do
      {out, code} = MixCmd.run(task, cd: dir, env: [{"MIX_ENV", "dev"}])
      if code != 0, do: raise("mix #{Enum.join(task, " ")} failed in #{dir}:\n#{out}")
    end

    :ok
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    index = Keyword.fetch!(opts, :index)
    GenServer.start_link(__MODULE__, opts, name: name(index))
  end

  @doc "Registered name of host `index`."
  @spec name(non_neg_integer()) :: atom()
  def name(index), do: :"tnh_load_device_host_#{index}"

  @spec await_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_ready(server, timeout \\ @startup_timeout) do
    GenServer.call(server, :await_ready, timeout + 1_000)
  end

  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @spec rpc(GenServer.server(), module(), atom(), list(), timeout()) :: any()
  def rpc(server, mod, fun, args, timeout \\ 60_000) do
    %{node: node, cookie: cookie} = info(server)
    _ = Node.set_cookie(node, cookie)
    true = Node.connect(node)
    :erpc.call(node, mod, fun, args, timeout)
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal, :timer.seconds(30))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    index = Keyword.fetch!(opts, :index)
    cookie = Keyword.fetch!(opts, :cookie)
    log = Keyword.get(opts, :log, Path.join(Config.work_dir(), "device_host_#{index}.log"))
    node = :"tnh_device_host_#{index}_#{:erlang.unique_integer([:positive])}@127.0.0.1"

    env =
      [
        {"MIX_ENV", "dev"},
        {"ERL_AFLAGS", "-name #{node} -setcookie #{cookie}"},
        {"DEVICE_HOST_DATA_DIR", Path.join(Config.work_dir(), "device_host_#{index}_data")},
        {"DEVICE_HOST_LOG_LEVEL", System.get_env("DEVICE_HOST_LOG_LEVEL", "warning")}
      ] ++
        for var <- ["NERVES_HUB_LINK_PATH", "NERVES_HUB_LINK_GITHUB", "NERVES_HUB_LINK_BRANCH"],
            value = System.get_env(var),
            do: {var, value}

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", wrapper(MixCmd.shell())]},
        {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
        {:cd, String.to_charlist(project_dir())}
      ])

    {:ok,
     %__MODULE__{
       index: index,
       port: port,
       node: node,
       cookie: String.to_atom(cookie),
       log: log,
       ready?: false
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, %{ready?: true} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, state) do
    _ = Node.set_cookie(state.node, state.cookie)
    deadline = System.monotonic_time(:millisecond) + @startup_timeout

    case poll(state.node, deadline) do
      :ok ->
        os_pid = :erpc.call(state.node, :os, :getpid, []) |> List.to_integer()
        Logger.info("device host #{state.index}: ready as #{state.node} (pid #{os_pid})")
        {:reply, :ok, %{state | ready?: true, os_pid: os_pid}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:index, :node, :cookie, :os_pid, :log]), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    File.mkdir_p!(Path.dirname(state.log))
    File.write!(state.log, data, [:append])
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("device host #{state.index} exited with status #{code}")
    {:stop, {:device_host_exited, code}, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_, _), do: :ok

  defp poll(node, deadline) do
    ready? =
      Node.connect(node) == true and
        match?({:module, _}, :erpc.call(node, Code, :ensure_loaded, [DeviceHost.Fleet], 5_000)) and
        is_pid(:erpc.call(node, Process, :whereis, [DeviceHost.Fleet], 5_000))

    cond do
      ready? -> :ok
      System.monotonic_time(:millisecond) > deadline -> {:error, :device_host_not_ready}
      true -> Process.sleep(500) && poll(node, deadline)
    end
  catch
    :error, _ -> Process.sleep(500) && poll(node, deadline)
  end

  # Same shape as the server wrapper: the child dies when our stdin closes.
  defp wrapper(mix) do
    """
    #{mix} run --no-halt &
    CHILD=$!
    trap 'kill -TERM $CHILD 2>/dev/null' TERM INT
    while IFS= read -r _; do :; done
    kill -TERM $CHILD 2>/dev/null
    wait $CHILD 2>/dev/null
    """
  end
end
