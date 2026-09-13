defmodule TestNervesHub.Config do
  @moduledoc """
  Thin accessors over the `:test_nerves_hub` application env so call sites
  don't have to remember the key shape.
  """

  @doc """
  Resolved path to a `nerves_hub_web` checkout. Looks up `NERVES_HUB_WEB_SOURCE`
  and clones if needed; see `TestNervesHub.WebSource`. Cached after first call.
  """
  def nerves_hub_web_path do
    case Application.get_env(:test_nerves_hub, :nerves_hub_web_path) do
      nil ->
        path = TestNervesHub.WebSource.resolve!()
        Application.put_env(:test_nerves_hub, :nerves_hub_web_path, path)
        path

      path ->
        path
    end
  end

  @doc """
  Package spec passed to `mix igniter.install` for nerves_hub_link.

  Default: `nerves_hub_link` (latest from hex). Override with
  `NERVES_HUB_LINK_PACKAGE`, accepting any igniter package format:
    * `nerves_hub_link@git:https://...`
    * `nerves_hub_link@github:org/repo[@ref]`
    * `nerves_hub_link@path:/abs/or/relative/path`
    * `nerves_hub_link@version` (e.g. `nerves_hub_link@2.10.0`)
  """
  def nerves_hub_link_package do
    System.get_env("NERVES_HUB_LINK_PACKAGE", "nerves_hub_link")
  end

  @doc """
  Contents of the `.tool-versions` written above generated firmware
  projects, so `mix firmware` runs with an Erlang/OTP whose major version
  matches the Nerves system's — Nerves refuses to build otherwise.

  Default: whatever the `nerves_hub_web` checkout pins, since both track
  current OTP. Override with `TEST_NERVES_HUB_FIRMWARE_TOOL_VERSIONS`
  (newline-separated `.tool-versions` lines, e.g.
  `"elixir 1.20.3-otp-29\nerlang 29.0.5"`), or set it to `""` to inherit
  the runner's toolchain.
  """
  @spec firmware_tool_versions() :: String.t() | nil
  def firmware_tool_versions do
    case System.get_env("TEST_NERVES_HUB_FIRMWARE_TOOL_VERSIONS") do
      nil ->
        path = Path.join(nerves_hub_web_path(), ".tool-versions")
        if File.exists?(path), do: File.read!(path), else: nil

      "" ->
        nil

      contents ->
        String.replace(contents, "\\n", "\n")
    end
  end

  @doc """
  CIDR for QEMU's user-mode network, or `nil` to keep QEMU's default
  (10.0.2.0/24). Defaults to 10.0.3.0/24 so a host that is itself on
  10.0.2.0/24 stays reachable from the guest; see `TestNervesHub.QEMU`.
  Override with `TEST_NERVES_HUB_QEMU_SUBNET`.
  """
  @spec qemu_guest_subnet() :: String.t() | nil
  def qemu_guest_subnet do
    case System.get_env("TEST_NERVES_HUB_QEMU_SUBNET", "10.0.3.0/24") do
      "" -> nil
      subnet -> subnet
    end
  end

  def work_dir, do: fetch!(:work_dir)
  def qemu_target, do: fetch!(:qemu_target)
  def web_port, do: fetch!(:web_port)
  def device_port, do: fetch!(:device_port)

  def postgres, do: fetch!(:postgres)
  def clickhouse, do: fetch!(:clickhouse)

  defp fetch!(key), do: Application.fetch_env!(:test_nerves_hub, key)
end
