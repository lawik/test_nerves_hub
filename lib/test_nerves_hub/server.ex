defmodule TestNervesHub.Server do
  @moduledoc """
  Manages one `nerves_hub_web` node for the test suite.

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

  ## One node or several

  The end-to-end tests start a single node under the default name — the
  "all" role, in the `dev` environment, which serves the web API and the
  device endpoint at once. The load suite (`TestNervesHub.Load`) starts
  several: that same node for the API plus any number of `device`-role
  nodes, usually in the `prod` environment so they run the configuration
  a deployment runs (websocket compression settings and the like live
  under `config_env() == :prod`). Nodes sharing a database cluster
  through `libcluster`'s Postgres strategy, exactly as deployed nodes do.

  ## Options

    * `:name` — registered name, default `#{inspect(__MODULE__)}`
    * `:role` — `"all"` (default), `"web"` or `"device"` (`NERVES_HUB_APP`)
    * `:mix_env` — `"dev"` (default) or `"prod"`
    * `:web_port` / `:device_port` — defaults from `TestNervesHub.Config`
    * `:status_port` — device-role health check port (prod only)
    * `:migrate?` — run `ecto.migrate` first, default `true`
    * `:prepare?` — run `deps.get` (and `compile` for prod), default `true`
    * `:log` — file the node's output is appended to, default
      `<work>/nerves_hub_web.log` (`<work>/<name>.log` for other names)
    * `:env` — extra environment variables, `[{"KEY", "value"}]`
    * `:cookie` — distribution cookie; nodes of one cluster share it.
      Default: a fresh one per node.
  """

  use GenServer
  require Logger

  alias TestNervesHub.{Config, MixCmd}

  @startup_timeout :timer.minutes(3)

  defmodule State do
    @moduledoc false
    defstruct [
      :name,
      :port,
      :node,
      :cookie,
      :role,
      :mix_env,
      :web_port,
      :device_port,
      :status_port,
      :log,
      :os_pid,
      :ready?,
      :buffer,
      :awaiting
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Block until the node's endpoint answers and RPC is up."
  @spec await_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_ready(server \\ __MODULE__, timeout \\ @startup_timeout)

  def await_ready(timeout, _) when is_integer(timeout), do: await_ready(__MODULE__, timeout)

  def await_ready(server, timeout) do
    GenServer.call(server, :await_ready, timeout + 1_000)
  end

  @doc "Connect to the running node and return its node name."
  @spec node_name(GenServer.server()) :: node()
  def node_name(server \\ __MODULE__), do: GenServer.call(server, :node_name)

  @doc """
  What the node is: `%{node, role, mix_env, web_port, device_port, os_pid}`.
  The `os_pid` is the BEAM's, read from the node itself, so it is the one
  to look up in `/proc` for RSS.
  """
  @spec info(GenServer.server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc """
  Call a function on the running nerves_hub_web node.
  Returns the result or raises on RPC failure.
  """
  @spec rpc(module(), atom(), list()) :: any()
  def rpc(mod, fun, args), do: rpc(__MODULE__, mod, fun, args, 30_000)

  # Two shapes share arity 4: `(mod, fun, args, timeout)` on the default
  # node and `(server, mod, fun, args)` on a named one. The guards tell
  # them apart by where the argument list sits.
  @spec rpc(module() | GenServer.server(), atom() | module(), atom() | list(), timeout() | list()) ::
          any()
  def rpc(mod, fun, args, timeout)
      when is_atom(fun) and is_list(args) and (is_integer(timeout) or timeout == :infinity),
      do: rpc(__MODULE__, mod, fun, args, timeout)

  def rpc(server, mod, fun, args) when is_atom(fun) and is_list(args),
    do: rpc(server, mod, fun, args, 30_000)

  @spec rpc(GenServer.server(), module(), atom(), list(), timeout()) :: any()
  def rpc(server, mod, fun, args, timeout) do
    {node, cookie} = GenServer.call(server, :node_and_cookie)
    ensure_connected!(node, cookie)
    :erpc.call(node, mod, fun, args, timeout)
  end

  @doc "Evaluate Elixir source on the node; returns the value."
  @spec eval(GenServer.server(), String.t(), timeout()) :: any()
  def eval(server \\ __MODULE__, code, timeout \\ 30_000) do
    {value, _binding} = rpc(server, Code, :eval_string, [code], timeout)
    value
  end

  @doc "Stop the node (SIGTERM to mix, then the port closes)."
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__), do: GenServer.stop(server, :normal, :timer.seconds(30))

  @doc """
  Return the CA PEM blob clients should trust when talking to this server.
  Pulled from the nerves_hub_web fixtures dir.
  """
  @spec ca_pem() :: String.t()
  def ca_pem do
    File.read!(Path.join(ssl_dir(), "ca.pem"))
  end

  @doc "The dev/test fixture certificates directory in the web checkout."
  @spec ssl_dir() :: Path.t()
  def ssl_dir, do: Path.join([Config.nerves_hub_web_path(), "test", "fixtures", "ssl"])

  # The hostname the fixture device certificate is issued for. Clients
  # send it as SNI regardless of the IP they dial.
  @doc false
  def device_cert_hostname, do: "device.nerves-hub.org"

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
  def init(opts) do
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    role = Keyword.get(opts, :role, "all")
    mix_env = Keyword.get(opts, :mix_env, "dev")
    web_port = Keyword.get(opts, :web_port, Config.web_port())
    device_port = Keyword.get(opts, :device_port, Config.device_port())
    status_port = Keyword.get(opts, :status_port, web_port + 40)
    log = Keyword.get(opts, :log, default_log(name))
    label = label(name)

    Logger.info("#{label}: bootstrapping (#{role}, #{mix_env})")

    pg = Config.postgres()
    ch = Config.clickhouse()

    Logger.info("#{label}: ensuring postgres database #{inspect(pg[:database])}")
    :ok = ensure_postgres_database!(pg)

    Logger.info("#{label}: ensuring clickhouse database #{inspect(ch[:database])}")
    :ok = ensure_clickhouse_database!(ch)

    if Keyword.get(opts, :prepare?, true) do
      Logger.info(
        "#{label}: preparing checkout (mix deps.get#{if mix_env == "prod", do: " + compile"})"
      )

      :ok = prepare_web_project!(mix_env)
    end

    if Keyword.get(opts, :migrate?, true) do
      Logger.info("#{label}: running migrations (mix ecto.migrate)")
      :ok = run_migrations!(pg, ch)
    end

    suffix = :erlang.unique_integer([:positive])
    cookie = Keyword.get(opts, :cookie, "test_nerves_hub_#{suffix}")
    node = :"nerves_hub_#{suffix}@127.0.0.1"

    Logger.info(
      "#{label}: starting mix phx.server (node #{node}, web :#{web_port}, device :#{device_port})"
    )

    env =
      node_env(pg, ch, node, cookie, %{
        role: role,
        mix_env: mix_env,
        web_port: web_port,
        device_port: device_port,
        status_port: status_port
      }) ++ Keyword.get(opts, :env, [])

    port = start_phoenix(env)

    {:ok,
     %State{
       name: name,
       port: port,
       node: node,
       cookie: String.to_atom(cookie),
       role: role,
       mix_env: mix_env,
       web_port: web_port,
       device_port: device_port,
       status_port: status_port,
       log: log,
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
    label = label(state.name)
    Logger.info("#{label}: waiting for HTTP endpoint on :#{probe_port(state)}")

    result =
      with :ok <- poll_http(probe_port(state), state, @startup_timeout) do
        Logger.info("#{label}: HTTP up; waiting for RPC node #{state.node}")

        case poll_node(state.node, state.cookie, @startup_timeout) do
          :ok ->
            Logger.info("#{label}: ready (HTTP + RPC) — node=#{state.node}")
            :ok

          other ->
            other
        end
      end

    state =
      case result do
        :ok ->
          os_pid = :erpc.call(state.node, :os, :getpid, []) |> List.to_integer()
          %{state | ready?: true, os_pid: os_pid}

        _ ->
          state
      end

    {:reply, result, state}
  end

  def handle_call(:node_name, _from, state), do: {:reply, state.node, state}

  def handle_call(:node_and_cookie, _from, state),
    do: {:reply, {state.node, state.cookie}, state}

  def handle_call(:info, _from, state) do
    info =
      Map.take(state, [
        :name,
        :node,
        :role,
        :mix_env,
        :web_port,
        :device_port,
        :status_port,
        :os_pid,
        :log
      ])

    {:reply, info, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    # Tee everything to a file so we can grep for auth/socket events
    # after a failing test, without having to keep the buffer in memory.
    File.mkdir_p!(Path.dirname(state.log))
    File.write!(state.log, data, [:append])

    if String.contains?(data, "[error]") or String.contains?(data, "[warning]") do
      Logger.debug("#{label(state.name)}: #{String.trim(data)}")
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    Logger.error("#{label(state.name)} exited with status #{code}")
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

  defp label(__MODULE__), do: "nerves_hub_web"
  defp label(name), do: inspect(name)

  defp default_log(__MODULE__), do: Path.join(Config.work_dir(), "nerves_hub_web.log")

  defp default_log(name) do
    Path.join(Config.work_dir(), "#{name |> inspect() |> String.replace(~r/[^\w.-]/, "_")}.log")
  end

  # A device-role node has no web endpoint; its health check answers instead.
  defp probe_port(%State{role: "device"} = state), do: state.status_port
  defp probe_port(state), do: state.web_port

  defp node_env(pg, ch, node, cookie, %{mix_env: "dev"} = n) do
    [
      {"DATABASE_URL", database_url(pg)},
      {"CLICKHOUSE_URL", clickhouse_url(ch)},
      {"WEB_PORT", to_string(n.web_port)},
      # device endpoint is web_port + 1 by default in the dev config
      {"DEVICE_PORT", to_string(n.device_port)},
      # Firmware download URLs are built from WEB_HOST. We use the host's
      # primary LAN IPv4 so the same address resolves correctly from both
      # the QEMU guest (via SLIRP NAT) and the server itself (own-address
      # short-circuit to loopback) — required for the delta builder to
      # fetch the firmware files it advertises.
      {"WEB_HOST", host_address()},
      {"NERVES_HUB_APP", n.role},
      {"MIX_ENV", "dev"},
      {"ERL_AFLAGS", "-name #{node} -setcookie #{cookie}"}
    ]
  end

  # Everything `config/runtime.exs` insists on under `config_env() == :prod`,
  # pointed at the same fixtures and databases the dev node uses. Secrets
  # are per-run throwaways. No S3, no SMTP: those stay unset and the
  # runtime config falls back to local files and the local mailer.
  defp node_env(pg, ch, node, cookie, %{mix_env: "prod"} = n) do
    host = host_address()

    [
      {"DATABASE_URL", database_url(pg)},
      {"DATABASE_SSL", "false"},
      {"DATABASE_AUTO_MIGRATOR", "false"},
      {"CLICKHOUSE_URL", clickhouse_url(ch)},
      {"NERVES_HUB_APP", n.role},
      {"MIX_ENV", "prod"},
      {"DEPLOY_ENV", "load"},
      {"SECRET_KEY_BASE", random_secret(64)},
      {"LIVE_VIEW_SIGNING_SALT", random_secret(16)},
      {"WEB_HOST", host},
      {"WEB_SCHEME", "http"},
      {"WEB_PORT", to_string(n.web_port)},
      {"HTTP_PORT", to_string(n.web_port)},
      {"WEB_FORWARDED_IP_HEADER", "none"},
      {"DEVICE_HOST", host},
      {"DEVICE_PORT", to_string(n.device_port)},
      {"DEVICE_HOST_STATUS_PORT", to_string(n.status_port)},
      {"DEVICE_SSL_KEYFILE", Path.join(ssl_dir(), "#{device_cert_hostname()}-key.pem")},
      {"DEVICE_SSL_CERTFILE", Path.join(ssl_dir(), "#{device_cert_hostname()}.pem")},
      {"DEVICE_SSL_CACERTFILE", Path.join(ssl_dir(), "ca.pem")},
      {"DEVICE_SHARED_SECRETS_ENABLED", "true"},
      {"ERL_AFLAGS", "-name #{node} -setcookie #{cookie}"}
    ]
  end

  defp random_secret(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode64(padding: false)

  defp start_phoenix(env) do
    web_path = Config.nerves_hub_web_path()

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["-c", phoenix_wrapper(MixCmd.shell())]},
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

  defp poll_http(port, state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll_http(port, state, deadline, System.monotonic_time(:millisecond))
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

  defp do_poll_http(port, state, deadline, last_log) do
    case Req.get("http://localhost:#{port}/", retry: false, receive_timeout: 1_000) do
      {:ok, %{status: status}} when status < 500 ->
        :ok

      reason ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, {:http_timeout, reason, tail_of_log(state)}}
        else
          now = System.monotonic_time(:millisecond)

          last_log =
            if now - last_log >= @poll_log_interval_ms do
              Logger.info("#{label(state.name)}: still waiting for HTTP on :#{port}")
              now
            else
              last_log
            end

          Process.sleep(500)
          do_poll_http(port, state, deadline, last_log)
        end
    end
  end

  defp tail_of_log(%State{log: log}) do
    case File.read(log) do
      {:ok, contents} -> contents |> String.split("\n") |> Enum.take(-30) |> Enum.join("\n")
      _ -> ""
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

  # Triggers the clone (if any) via Config.nerves_hub_web_path/0, makes
  # sure deps are fetched, and compiles for the node's environment. The
  # boot itself would compile too, but a full rebuild takes longer than
  # the HTTP startup budget and its errors would surface as a silent
  # timeout. Idempotent against an up-to-date build.
  defp prepare_web_project!(mix_env) do
    web_path = Config.nerves_hub_web_path()
    env = [{"MIX_ENV", mix_env}]

    {out, code} = MixCmd.run(["deps.get"], cd: web_path, env: env)
    if code != 0, do: raise("mix deps.get failed in #{web_path} (status #{code}):\n#{out}")

    {out, code} = MixCmd.run(["compile"], cd: web_path, env: env)

    if code != 0,
      do: raise("MIX_ENV=#{mix_env} mix compile failed in #{web_path} (status #{code}):\n#{out}")

    :ok
  end

  defp run_migrations!(pg, ch) do
    web_path = Config.nerves_hub_web_path()

    env = [
      {"DATABASE_URL", database_url(pg)},
      {"CLICKHOUSE_URL", clickhouse_url(ch)},
      {"MIX_ENV", "dev"}
    ]

    {out, code} = MixCmd.run(["ecto.migrate"], cd: web_path, env: env)

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
