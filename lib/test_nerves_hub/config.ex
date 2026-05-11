defmodule TestNervesHub.Config do
  @moduledoc """
  Thin accessors over the `:test_nerves_hub` application env so call sites
  don't have to remember the key shape.
  """

  def nerves_hub_web_path, do: fetch!(:nerves_hub_web_path)
  def work_dir, do: fetch!(:work_dir)
  def qemu_target, do: fetch!(:qemu_target)
  def web_port, do: fetch!(:web_port)
  def device_port, do: fetch!(:device_port)

  def postgres, do: fetch!(:postgres)
  def clickhouse, do: fetch!(:clickhouse)

  defp fetch!(key), do: Application.fetch_env!(:test_nerves_hub, key)
end
