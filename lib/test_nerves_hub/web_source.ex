defmodule TestNervesHub.WebSource do
  @moduledoc """
  Resolves the `nerves_hub_web` source to a usable local path.

  `NERVES_HUB_WEB_SOURCE` can be either:
    * a path to an existing directory (used in-place), or
    * a git URL (https, ssh, or scp-style `user@host:path`) — cloned
      into `<work>/nerves_hub_web` on first use and reused thereafter.

  `NERVES_HUB_WEB_REF` chooses the branch/tag/commit (default `main`).

  Default source: the upstream `nerves-hub/nerves_hub_web` repo on
  GitHub, `main` branch — so a fresh checkout of this test runner
  needs zero local setup beyond the env vars for the databases.

  Updates: cloning is one-shot. To pick up upstream changes either
  delete the work dir or `git pull` it yourself. We deliberately do
  not auto-fetch on every run so a developer mid-investigation isn't
  surprised by a moving working tree.
  """

  require Logger

  alias TestNervesHub.Config

  @default_url "https://github.com/nerves-hub/nerves_hub_web.git"
  @default_ref "main"

  @doc """
  Return an absolute path to a usable `nerves_hub_web` checkout.

  Side effect: may clone into `<work_dir>/nerves_hub_web` if the
  configured source is a git URL and no checkout exists yet.
  """
  @spec resolve!() :: Path.t()
  def resolve! do
    source = System.get_env("NERVES_HUB_WEB_SOURCE") || @default_url
    ref = System.get_env("NERVES_HUB_WEB_REF") || @default_ref

    expanded = Path.expand(source)

    cond do
      File.dir?(expanded) ->
        expanded

      File.dir?(source) ->
        Path.expand(source)

      git_url?(source) ->
        ensure_cloned!(source, ref)

      true ->
        raise """
        NERVES_HUB_WEB_SOURCE=#{inspect(source)} is neither an existing
        directory nor a recognized git URL. Set it to a local path or a
        git URL (https://..., git@..., ssh://..., or user@host:path).
        """
    end
  end

  # The clone goes inside the test runner's work dir, which is already
  # in .gitignore, so it doesn't pollute the user's working tree.
  defp ensure_cloned!(url, ref) do
    dest = Path.join(Config.work_dir(), "nerves_hub_web")

    if File.dir?(Path.join(dest, ".git")) do
      Logger.info("Using existing nerves_hub_web checkout at #{dest}")
      dest
    else
      File.mkdir_p!(Path.dirname(dest))
      Logger.info("Cloning #{url} (#{ref}) into #{dest}")

      case System.cmd("git", ["clone", "--branch", ref, "--depth", "1", url, dest],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          dest

        {out, code} ->
          # Some refs (commits, non-default branches on older git) don't
          # work with --depth 1 + --branch. Fall back to a full clone.
          Logger.warning("Shallow clone failed (code #{code}): #{out}\nRetrying without --depth.")
          retry_clone!(url, ref, dest)
      end
    end
  end

  defp retry_clone!(url, ref, dest) do
    _ = File.rm_rf(dest)

    with {_, 0} <- System.cmd("git", ["clone", url, dest], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["checkout", ref], cd: dest, stderr_to_stdout: true) do
      dest
    else
      {out, code} ->
        raise "git clone of #{url}@#{ref} into #{dest} failed (code #{code}):\n#{out}"
    end
  end

  # Anything containing "://" (https/ssh/git) or the scp-style `user@host:path`
  # shape counts as a git URL. The scp form is the tricky one — it has a colon
  # but no scheme, so we look for `<something>@<host>:`.
  defp git_url?(source) do
    String.contains?(source, "://") or
      Regex.match?(~r/^[^\s:]+@[^\s:]+:/, source) or
      String.ends_with?(source, ".git")
  end
end
