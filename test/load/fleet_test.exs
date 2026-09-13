defmodule TestNervesHub.Load.FleetTest do
  @moduledoc """
  Regression gate for what a connected device costs a `nerves_hub_web`
  device node.

  Excluded by default — run with `mix test --only load`. Thresholds come
  from the environment so a CI job can tighten them as the numbers come
  down:

    * `LOAD_MAX_RSS_PER_DEVICE_KB` — RSS growth per connected device over
      the hold, per device-role node (default 600)
    * `LOAD_MAX_ERLANG_RETAINED_PER_DEVICE_KB` — `:erlang.memory(:total)`
      not released per device after disconnect and settle (default 32).
      RSS is not gated on retention: the C allocator keeps pages the BEAM
      has freed, and that is not a leak.

  Per-device figures carry the node's fixed costs spread over the fleet,
  so run the gate with a few hundred devices (`LOAD_DEVICES`), not a
  handful.
  """

  use ExUnit.Case, async: false

  alias TestNervesHub.Load
  alias TestNervesHub.Load.Scenario

  @moduletag :load
  @moduletag timeout: :timer.hours(2)

  test "a fleet connects, holds, and the nodes give the memory back" do
    scenario = Scenario.from_env()
    %{summary: summary, dir: dir} = Load.run(scenario)

    IO.puts(TestNervesHub.Load.Report.to_markdown(summary))
    IO.puts("report: #{dir}")

    assert summary.online_at_hold >= scenario.devices

    max_rss = env_int("LOAD_MAX_RSS_PER_DEVICE_KB", 600) * 1024
    max_retained = env_int("LOAD_MAX_ERLANG_RETAINED_PER_DEVICE_KB", 32) * 1024

    for {node, s} <- summary.servers, s.role in ["device", "all"] do
      assert s.rss_per_device_bytes <= max_rss,
             "#{node}: #{div(s.rss_per_device_bytes, 1024)} kB RSS per device over #{div(max_rss, 1024)} kB"

      assert s.erlang_retained_per_device_bytes <= max_retained,
             "#{node}: #{div(s.erlang_retained_per_device_bytes, 1024)} kB of Erlang memory per device not released after disconnect"
    end
  end

  defp env_int(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
