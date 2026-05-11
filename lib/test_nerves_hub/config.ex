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

  def work_dir, do: fetch!(:work_dir)
  def qemu_target, do: fetch!(:qemu_target)
  def web_port, do: fetch!(:web_port)
  def device_port, do: fetch!(:device_port)

  def postgres, do: fetch!(:postgres)
  def clickhouse, do: fetch!(:clickhouse)

  defp fetch!(key), do: Application.fetch_env!(:test_nerves_hub, key)
end
