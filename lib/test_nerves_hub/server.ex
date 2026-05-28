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

  @doc """
  IPv4 address to advertise as `WEB_HOST` to the spawned `nerves_hub_web`
  and to bake into device firmware as the server host.

  We need an address that is reachable from BOTH directions:
    * The QEMU guest dials it (firmware download + websocket).
    * nerves_hub_web's own delta builder fetches firmware from its own
      public URL, so the server has to be able to reach itself at the
      same address.

  `10.0.2.2` (QEMU's host-from-guest alias) is only routable from the
  guest, not from the host. `127.0.0.1` is only the host's loopback, not
  reachable from the guest. The host's primary LAN IPv4 satisfies both:
  the guest's NAT routes through the host's stack, and the host
  recognises the address as its own and short-circuits to loopback.

  `WEB_HOST_OVERRIDE` forces a specific address — handy if the
  autodetected interface is on a VPN, or for CI where the routing
  topology is known up front.
  """
  @spec host_address() :: String.t()
  def host_address do
    case System.get_env("WEB_HOST_OVERRIDE") do
      override when is_binary(override) and override != "" ->
        override

      _ ->
        detect_host_address!()
    end
  end

  defp detect_host_address! do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        ifs
        |> Enum.flat_map(&interface_ipv4s/1)
        |> Enum.find(&routable_ipv4?/1)
        |> case do
          {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
          nil -> raise_no_host_address()
        end

      {:error, reason} ->
        raise "Failed to enumerate network interfaces: #{inspect(reason)}"
    end
  end

  defp interface_ipv4s({_name, opts}) do
    # Only consider up + running interfaces; skip the loopback flag explicitly
    # so we don't pick lo0 even if it has a non-127 alias.
    flags = Keyword.get(opts, :flags, [])

    if :up in flags and :running in flags and :loopback not in flags do
      for {:addr, {_, _, _, _} = ip4} <- opts, do: ip4
    else
      []
    end
  end

  defp routable_ipv4?({127, _, _, _}), do: false
  defp routable_ipv4?({169, 254, _, _}), do: false
  defp routable_ipv4?({_, _, _, _}), do: true
  defp routable_ipv4?(_), do: false

  defp raise_no_host_address do
    raise """
    Could not autodetect a non-loopback IPv4 address for nerves_hub_web to
    advertise. Both the QEMU device and the server (for delta generation)
    need to reach the same URL.

    Set WEB_HOST_OVERRIDE to a routable address before running tests, for
    example:

        WEB_HOST_OVERRIDE=192.168.1.42 mix test

    A LAN IP works; 127.0.0.1 will not (the QEMU guest can't reach the
    host's loopback).
    """
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    Logger.info("nerves_hub_web: bootstrapping test server")

    pg = Config.postgres()
    ch = Config.clickhouse()

    Logger.info("nerves_hub_web: ensuring postgres database #{inspect(pg[:database])}")
    :ok = ensure_postgres_database!(pg)

    Logger.info("nerves_hub_web: ensuring clickhouse database #{inspect(ch[:database])}")
    :ok = ensure_clickhouse_database!(ch)

    Logger.info("nerves_hub_web: preparing checkout (mix deps.get)")
    :ok = prepare_web_project!()

    Logger.info("nerves_hub_web: running migrations (mix ecto.migrate)")
    :ok = run_migrations!(pg, ch)

    suffix = :erlang.unique_integer([:positive])
    cookie = "test_nerves_hub_#{suffix}"
    node = :"nerves_hub_#{suffix}@127.0.0.1"

    Logger.info(
      "nerves_hub_web: starting mix phx.server (node #{node}, web :#{Config.web_port()}, device :#{Config.device_port()})"
    )

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
    Logger.info("nerves_hub_web: waiting for HTTP endpoint on :#{state.web_port}")

    result =
      with :ok <- poll_http(state.web_port, @startup_timeout) do
        Logger.info("nerves_hub_web: HTTP up; waiting for RPC node #{state.node}")

        case poll_node(state.node, state.cookie, @startup_timeout) do
          :ok ->
            Logger.info("nerves_hub_web: ready (HTTP + RPC) — node=#{state.node}")
            :ok

          other ->
            other
        end
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
      # Firmware download URLs are built from WEB_HOST. We use the host's
      # primary LAN IPv4 so the same address resolves correctly from both
      # the QEMU guest (via SLIRP NAT) and the server itself (own-address
      # short-circuit to loopback) — required for the delta builder to
      # fetch the firmware files it advertises.
      {"WEB_HOST", host_address()},
      {"MIX_ENV", "dev"},
      {"ERL_AFLAGS", "-name #{node} -setcookie #{cookie}"}
    ]

    mix = System.find_executable("mix") || raise "mix not found on PATH"

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-c", phoenix_wrapper(mix)]},
      {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
      {:cd, String.to_charlist(web_path)}
    ])
  end

  # Wrap `mix phx.server` so the child dies with us. When the BEAM exits
  # (including hard exits like a MatchError in test_helper.exs that bypass
  # GenServer.terminate/2), the Port's stdin closes, `read` returns EOF, and
  # the wrapper kills mix. Also forwards SIGTERM from terminate/2 to mix
  # via the trap. Result: no more orphaned phx.server holding port 4900.
  defp phoenix_wrapper(mix) do
    """
    #{mix} phx.server &
    CHILD=$!
    trap 'kill -TERM $CHILD 2>/dev/null' TERM INT
    # Block until stdin closes (Port closes when BEAM exits) or a signal arrives.
    while IFS= read -r _; do :; done
    kill -TERM $CHILD 2>/dev/null
    wait $CHILD 2>/dev/null
    """
  end

  # A "still waiting" log every ~5s — frequent enough that a hung startup
  # tells you which gate it's stuck on, rare enough not to spam.
  @poll_log_interval_ms 5_000

  defp poll_http(port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_http(port, deadline, System.monotonic_time(:millisecond))
  end

  # Verifies we can reach the RPC node AND that NervesHub.Accounts is loaded.
  # Without this, await_ready can succeed against a stale server still bound
  # to the HTTP port while our newly-spawned server failed to start.
  defp poll_node(node, cookie, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    _ = Node.set_cookie(node, cookie)
    do_poll_node(node, deadline, System.monotonic_time(:millisecond))
  end

  defp do_poll_node(node, deadline, last_log) do
    {ok?, reason} =
      case Node.connect(node) do
        true ->
          case :erpc.call(node, Code, :ensure_loaded, [NervesHub.Accounts], 5_000) do
            {:module, _} -> {true, nil}
            other -> {false, {:module_not_loaded, other}}
          end

        other ->
          {false, {:node_connect, other}}
      end

    cond do
      ok? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, {:rpc_not_ready, reason}}

      true ->
        now = System.monotonic_time(:millisecond)

        last_log =
          if now - last_log >= @poll_log_interval_ms do
            Logger.info(
              "nerves_hub_web: still waiting for RPC node #{node} (last: #{inspect(reason)})"
            )

            now
          else
            last_log
          end

        Process.sleep(500)
        do_poll_node(node, deadline, last_log)
    end
  end

  defp do_poll_http(port, deadline, last_log) do
    case Req.get("http://localhost:#{port}/", retry: false, receive_timeout: 1_000) do
      {:ok, %{status: status}} when status < 500 ->
        :ok

      reason ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, {:http_timeout, reason}}
        else
          now = System.monotonic_time(:millisecond)

          last_log =
            if now - last_log >= @poll_log_interval_ms do
              Logger.info("nerves_hub_web: still waiting for HTTP on :#{port}")
              now
            else
              last_log
            end

          Process.sleep(500)
          do_poll_http(port, deadline, last_log)
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
