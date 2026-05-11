defmodule TestNervesHub.Server do
  @moduledoc """
  Manages a `nerves_hub_web` instance for the test suite.

  Why a separate process and not a path dep:
    * the web app is a full Phoenix application with its own ecto repos
      and runtime config; bringing it in as a path dep would couple the
      test runner to its compile graph and pollute the test runner's
      application env.
    * We want it to behave as it does in production: a separate OS process
      with the same `mix phx.server` entry point developers use.

  Org/product/device creation runs through Erlang distribution: the server
  is booted with a known node name and cookie, and `rpc/4` calls into
  `NervesHub.*` contexts directly.
  """

  use GenServer
  require Logger

  alias TestNervesHub.Config

  @startup_timeout :timer.minutes(2)

  defmodule State do
    @moduledoc false
    defstruct [:port, :node, :cookie, :web_port, :device_port, :ready?, :buffer, :awaiting]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Block until the web endpoint responds to HTTP."
  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout \\ @startup_timeout) do
    GenServer.call(__MODULE__, :await_ready, timeout + 1_000)
  end

  @doc "Connect to the running node and return its node name."
  @spec node_name() :: node()
  def node_name, do: GenServer.call(__MODULE__, :node_name)

  @doc """
  Call a function on the running nerves_hub_web node.
  Returns the result or `{:badrpc, _}` on error.
  """
  @spec rpc(module(), atom(), list(), timeout()) :: any()
  def rpc(mod, fun, args, timeout \\ 30_000) do
    {node, cookie} = GenServer.call(__MODULE__, :node_and_cookie)
    ensure_connected!(node, cookie)
    :erpc.call(node, mod, fun, args, timeout)
  end

  @doc """
  Return the CA PEM blob clients should trust when talking to this server.
  Pulled from the nerves_hub_web fixtures dir.
  """
  @spec ca_pem() :: String.t()
  def ca_pem do
    path = Path.join([Config.nerves_hub_web_path(), "test", "fixtures", "ssl", "ca.pem"])
    File.read!(path)
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    pg = Config.postgres()
    ch = Config.clickhouse()

    :ok = ensure_postgres_database!(pg)
    :ok = ensure_clickhouse_database!(ch)
    :ok = prepare_web_project!()
    :ok = run_migrations!(pg, ch)

    suffix = :erlang.unique_integer([:positive])
    cookie = "test_nerves_hub_#{suffix}"
    node = :"nerves_hub_#{suffix}@127.0.0.1"

    port = start_phoenix(pg, ch, node, cookie)

    {:ok,
     %State{
       port: port,
       node: node,
       cookie: String.to_atom(cookie),
       web_port: Config.web_port(),
       device_port: Config.device_port(),
       ready?: false,
       buffer: "",
       awaiting: nil
     }}
  end

  @impl true
  def handle_call(:await_ready, _from, %State{ready?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:await_ready, _from, state) do
    result =
      with :ok <- poll_http(state.web_port, @startup_timeout),
           :ok <- poll_node(state.node, state.cookie, @startup_timeout) do
        :ok
      end

    {:reply, result, %{state | ready?: result == :ok}}
  end

  def handle_call(:node_name, _from, state), do: {:reply, state.node, state}

  def handle_call(:node_and_cookie, _from, state),
    do: {:reply, {state.node, state.cookie}, state}

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    # Tee everything to a file so we can grep for auth/socket events
    # after a failing test, without having to keep the buffer in memory.
    log_path = Path.join(Config.work_dir(), "nerves_hub_web.log")
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, data, [:append])

    if String.contains?(data, "[error]") or String.contains?(data, "[warning]") do
      Logger.debug("nerves_hub_web: #{String.trim(data)}")
    end

    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    Logger.error("nerves_hub_web exited with status #{code}")
    {:stop, {:server_exited, code}, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{port: port}) when is_port(port) do
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

  # --- internals ---

  defp start_phoenix(pg, ch, node, cookie) do
    web_path = Config.nerves_hub_web_path()
    web_port = Config.web_port()
    device_port = Config.device_port()

    env = [
      {"DATABASE_URL", database_url(pg)},
      {"CLICKHOUSE_URL", clickhouse_url(ch)},
      {"WEB_PORT", to_string(web_port)},
      # device endpoint is web_port + 1 by default in the dev config
      {"DEVICE_PORT", to_string(device_port)},
      {"MIX_ENV", "dev"},
      {"ERL_AFLAGS", "-name #{node} -setcookie #{cookie}"}
    ]

    Port.open({:spawn_executable, System.find_executable("mix")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["phx.server"]},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
      {:cd, String.to_charlist(web_path)}
    ])
  end

  defp poll_http(port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_http(port, deadline)
  end

  # Verifies we can reach the RPC node AND that NervesHub.Accounts is loaded.
  # Without this, await_ready can succeed against a stale server still bound
  # to the HTTP port while our newly-spawned server failed to start.
  defp poll_node(node, cookie, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    _ = Node.set_cookie(node, cookie)
    do_poll_node(node, deadline)
  end

  defp do_poll_node(node, deadline) do
    with true <- Node.connect(node),
         {:module, _} <- :erpc.call(node, Code, :ensure_loaded, [NervesHub.Accounts], 5_000) do
      :ok
    else
      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :rpc_not_ready}
        else
          Process.sleep(500)
          do_poll_node(node, deadline)
        end
    end
  end

  defp do_poll_http(port, deadline) do
    case Req.get("http://localhost:#{port}/", retry: false, receive_timeout: 1_000) do
      {:ok, %{status: status}} when status < 500 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :timeout}
        else
          Process.sleep(500)
          do_poll_http(port, deadline)
        end
    end
  end

  defp ensure_postgres_database!(pg) do
    %URI{host: host, port: port, userinfo: userinfo, path: _} = URI.parse(pg[:url])
    [user, pass] = String.split(userinfo || "postgres:postgres", ":", parts: 2)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: host || "localhost",
        port: port || 5432,
        username: user,
        password: pass,
        database: "postgres"
      )

    case Postgrex.query(conn, "SELECT 1 FROM pg_database WHERE datname=$1", [pg[:database]]) do
      {:ok, %{num_rows: 0}} ->
        {:ok, _} = Postgrex.query(conn, ~s|CREATE DATABASE "#{pg[:database]}"|, [])

      _ ->
        :ok
    end

    GenServer.stop(conn)
    :ok
  end

  # Triggers the clone (if any) via Config.nerves_hub_web_path/0 and
  # makes sure deps are fetched. A fresh checkout will fail `ecto.migrate`
  # otherwise. Idempotent against an already-resolved local checkout.
  defp prepare_web_project! do
    web_path = Config.nerves_hub_web_path()

    {out, code} =
      System.cmd("mix", ["deps.get"],
        cd: web_path,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    if code != 0, do: raise("mix deps.get failed in #{web_path} (status #{code}):\n#{out}")
    :ok
  end

  defp run_migrations!(pg, ch) do
    web_path = Config.nerves_hub_web_path()

    env = [
      {"DATABASE_URL", database_url(pg)},
      {"CLICKHOUSE_URL", clickhouse_url(ch)},
      {"MIX_ENV", "dev"}
    ]

    {out, code} =
      System.cmd("mix", ["ecto.migrate"], cd: web_path, env: env, stderr_to_stdout: true)

    if code != 0 do
      raise "ecto.migrate failed (status #{code}):\n#{out}"
    end

    :ok
  end

  defp ensure_clickhouse_database!(ch) do
    body = "CREATE DATABASE IF NOT EXISTS #{ch[:database]}"

    case Req.post(ch[:url], body: body) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> raise "Failed to create ClickHouse DB: #{inspect(other)}"
    end
  end

  defp database_url(pg) do
    %URI{} = uri = URI.parse(pg[:url])
    %{uri | path: "/" <> pg[:database]} |> URI.to_string()
  end

  defp clickhouse_url(ch) do
    %URI{} = uri = URI.parse(ch[:url])
    %{uri | path: "/" <> ch[:database], query: nil} |> URI.to_string()
  end

  defp ensure_connected!(node, cookie) do
    # Per-node cookie: lets us talk to the nerves_hub_web node without
    # globally overwriting our cookie for other connections.
    _ = Node.set_cookie(node, cookie)

    case Node.connect(node) do
      true -> :ok
      :ignored -> raise "Local node not alive — start with --name/--sname"
      false -> raise "Failed to connect to #{node}"
    end
  end
end
