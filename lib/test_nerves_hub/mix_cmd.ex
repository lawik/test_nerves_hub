defmodule TestNervesHub.MixCmd do
  @moduledoc """
  Runs `mix` for a project directory with that project's own toolchain.

  The runner drives three different Mix projects (`nerves_hub_web`, a
  generated firmware project, and itself) and they don't agree on an
  Elixir version: `nerves_hub_web` pins a newer Elixir than the runner
  needs. Spawning the bare `mix` on the runner's `PATH` therefore fails
  the moment the web app's `mix.exs` checks its `elixir:` requirement.

  Resolution order:

    1. `TEST_NERVES_HUB_MIX` — a command prefix, split on whitespace,
       e.g. `"mise exec -- mix"` or `"asdf exec mix"`. Used verbatim.
    2. `mise` on `PATH` or at `~/.local/bin/mise` → `mise exec -- mix`.
       mise resolves `.tool-versions` from the subprocess cwd, so each
       project gets its own toolchain without the runner knowing which.
    3. Plain `mix` from `PATH`.
  """

  @doc "Argv (executable first) that runs `mix` for a project at `cd`."
  @spec argv() :: [String.t()]
  def argv do
    case System.get_env("TEST_NERVES_HUB_MIX") do
      prefix when is_binary(prefix) and prefix != "" ->
        [exe | rest] = String.split(prefix)
        [System.find_executable(exe) || exe | rest]

      _ ->
        case find_mise() do
          nil -> [System.find_executable("mix") || raise("mix not found on PATH")]
          mise -> [mise, "exec", "--", "mix"]
        end
    end
  end

  @doc """
  `System.cmd/3` for a mix task. `opts` are passed through; `:cd` is
  required so the toolchain resolves against the right project.
  """
  @spec run([String.t()], keyword()) :: {Collectable.t(), non_neg_integer()}
  def run(args, opts) when is_list(args) do
    cd = Keyword.fetch!(opts, :cd)
    [exe | prefix] = argv()
    {out, code} = System.cmd(exe, prefix ++ args, Keyword.put_new(opts, :stderr_to_stdout, true))
    warn_if_compiled(args, cd, out)
    {out, code}
  end

  # A task that was not asked to compile but did means the build was stale
  # or broken, and that is worth knowing: the compile output otherwise
  # vanishes with the successful task, and the next `phx.server` boot pays
  # for whatever went wrong in it.
  defp warn_if_compiled([task | _], cd, out) when task not in ["compile", "deps.compile"] do
    if is_binary(out) and String.contains?(out, "Compiling ") do
      lines =
        out |> String.split("\n") |> Enum.filter(&String.contains?(&1, ["Compiling ", "==> "]))

      require Logger

      Logger.warning(
        "mix #{task} in #{cd} compiled code it was not expected to (#{length(lines)} lines):\n" <>
          Enum.join(Enum.take(lines, 12), "\n")
      )
    end
  end

  defp warn_if_compiled(_, _, _), do: :ok

  @doc "Shell-quoted command line for embedding in `sh -c` wrappers."
  @spec shell() :: String.t()
  def shell, do: argv() |> Enum.map_join(" ", &shell_quote/1)

  defp find_mise do
    System.find_executable("mise") ||
      Enum.find([Path.expand("~/.local/bin/mise")], &File.exists?/1)
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
