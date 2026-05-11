defmodule TestNervesHub.QEMU do
  @moduledoc """
  Boots a built Nerves firmware in QEMU and exposes a synchronous
  `eval/3` for evaluating Elixir snippets on the device.

  Communication is over the QEMU serial console (attached to stdio).
  We rely on the IEx prompt that the Nerves runtime starts there.
  To make snippet evaluation robust against interleaved log lines, each
  call is wrapped in unique BEGIN/END markers; the output is captured
  between them and `inspect`ed result is parsed back.

  Why a GenServer: the Port emits chunked, asynchronous data we have to
  buffer; one process owns the buffer and serializes eval requests.
  """

  use GenServer
  require Logger

  alias TestNervesHub.Config

  @type t :: pid()

  @boot_timeout :timer.minutes(2)
  @eval_timeout :timer.seconds(15)

  defmodule State do
    @moduledoc false
    defstruct [:port, :firmware, :project_path, :buffer, :awaiting, :id, :ready?]
  end

  @doc """
  Start QEMU with the given firmware artifact.

  Options:
    * `:firmware` (required) — path to the `.fw` file
    * `:project_path` (required) — path of the firmware mix project,
      because `mix qemu` is resolved through the project's deps
    * `:name` — registry name to track the device (default: random)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || :"device_#{:erlang.unique_integer([:positive])}"
    GenServer.start_link(__MODULE__, Map.new(opts), name: via(name))
  end

  defp via(name), do: {:via, Registry, {__MODULE__.Registry, name}}

  @doc """
  Block until the device's IEx prompt is reachable. Idempotent.
  """
  @spec await_ready(t(), timeout()) :: :ok | {:error, term()}
  def await_ready(pid, timeout \\ @boot_timeout) do
    GenServer.call(pid, :await_ready, timeout + 1_000)
  end

  @doc """
  Evaluate Elixir source on the device. The snippet must be a single
  expression (it will be wrapped in markers and inspected).
  """
  @spec eval(t(), String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def eval(pid, source, timeout \\ @eval_timeout) do
    GenServer.call(pid, {:eval, source}, timeout + 1_000)
  end

  @doc "Cleanly stop the QEMU instance."
  @spec stop(t()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal, :timer.seconds(10))

  # --- GenServer ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cmd = build_qemu_command(opts)

    port =
      Port.open({:spawn_executable, cmd.executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: cmd.args,
        env: cmd.env,
        cd: opts.project_path
      ])

    {:ok,
     %State{
       port: port,
       firmware: opts.firmware,
       project_path: opts.project_path,
       buffer: "",
       awaiting: nil,
       id: 0,
       ready?: false
     }}
  end

  @impl true
  def handle_call(:await_ready, from, %State{ready?: true} = state) do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, %{state | awaiting: {:ready, from}}}
  end

  def handle_call({:eval, source}, from, %State{ready?: true} = state) do
    id = state.id + 1
    marker = "TNH_#{id}_#{:erlang.unique_integer([:positive])}"
    wrapped = wrap_for_eval(source, marker)

    Port.command(state.port, wrapped <> "\n")
    {:noreply, %{state | id: id, awaiting: {:eval, from, marker, ""}}}
  end

  def handle_call({:eval, _}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) do
    state = %{state | buffer: state.buffer <> data}
    state = maybe_detect_ready(state)
    state = maybe_drain_eval(state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    Logger.warning("QEMU exited with status #{code}")
    {:stop, {:qemu_exited, code}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- internals ---

  # The "ready" signal is the first IEx prompt we see in the buffer.
  # Nerves uses `iex(app@nerves)1>` style prompts by default.
  defp maybe_detect_ready(%State{ready?: false} = state) do
    if Regex.match?(~r/iex\(.*\)\d+>/, state.buffer) do
      state = %{state | ready?: true, buffer: ""}

      case state.awaiting do
        {:ready, from} ->
          GenServer.reply(from, :ok)
          %{state | awaiting: nil}

        _ ->
          state
      end
    else
      state
    end
  end

  defp maybe_detect_ready(state), do: state

  defp maybe_drain_eval(%State{awaiting: {:eval, from, marker, _}} = state) do
    buffer = state.buffer
    begin_token = "<<BEGIN:" <> marker <> ">>"
    end_token = "<<END:" <> marker <> ">>"

    with {:ok, _, rest} <- split_on(buffer, begin_token),
         {:ok, captured, after_end} <- split_on(rest, end_token) do
      reply = parse_capture(captured)
      GenServer.reply(from, reply)
      %{state | awaiting: nil, buffer: after_end}
    else
      _ -> state
    end
  end

  defp maybe_drain_eval(state), do: state

  defp split_on(buffer, token) do
    case :binary.split(buffer, token) do
      [before, after_] -> {:ok, before, after_}
      [_] -> :error
    end
  end

  # The on-device snippet prints a marker, then a base64'd binary term of the
  # result. base64 keeps it on one line and binary-term keeps Elixir terms.
  defp wrap_for_eval(source, marker) do
    """
    (fn ->
      IO.puts("<<BEGIN:#{marker}>>")
      result = try do
        {:ok, (#{source})}
      rescue
        e -> {:error, {:exception, Exception.format(:error, e, __STACKTRACE__)}}
      catch
        kind, reason -> {:error, {kind, inspect(reason)}}
      end
      IO.puts(Base.encode64(:erlang.term_to_binary(result)))
      IO.puts("<<END:#{marker}>>")
    end).()
    """
    |> String.replace("\n", " ")
  end

  defp parse_capture(captured) do
    line =
      captured
      |> String.split("\n", trim: true)
      |> Enum.find(fn l -> Regex.match?(~r/^[A-Za-z0-9+\/=]+$/, String.trim(l)) end)

    with bin when is_binary(bin) <- line,
         {:ok, raw} <- Base.decode64(String.trim(bin)),
         {:ok, term} <- safe_binary_to_term(raw) do
      term
    else
      _ -> {:error, {:unparseable, captured}}
    end
  end

  defp safe_binary_to_term(raw) do
    {:ok, :erlang.binary_to_term(raw, [:safe])}
  rescue
    _ -> {:error, :bad_term}
  end

  # `mix qemu` is provided by nerves_system_qemu_aarch64 and resolved through
  # the firmware project's deps, so we shell out to mix in that project dir.
  defp build_qemu_command(opts) do
    target = Application.get_env(:test_nerves_hub, :qemu_target) || Config.qemu_target()

    %{
      executable: System.find_executable("mix") || raise("mix not found"),
      args: ["qemu"],
      env: [
        {"MIX_TARGET", target},
        {"MIX_ENV", "dev"},
        {"NERVES_FW_IMAGE", opts.firmware}
      ]
    }
  end
end
