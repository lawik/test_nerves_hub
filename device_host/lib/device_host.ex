defmodule DeviceHost do
  @moduledoc """
  A BEAM node that stands in for many NervesHub devices.

  Each device is a full `nerves_hub_link` tree (socket, update manager,
  extensions) running as its own `NervesHubLink.Instance`, so what reaches
  NervesHub is what a real device sends: the same join, the same heartbeats,
  the same health reports. Only what would touch hardware — rebooting,
  writing firmware to flash, resolving a location — is replaced.

  The test runner (`TestNervesHub.Load`) starts one or more of these nodes
  as OS processes, then drives them over Erlang distribution through
  `DeviceHost.Fleet`.
  """

  @doc "See `DeviceHost.Fleet.start_devices/2`."
  defdelegate start_devices(specs, opts \\ []), to: DeviceHost.Fleet

  @doc "See `DeviceHost.Fleet.stop_devices/1`."
  defdelegate stop_devices(which), to: DeviceHost.Fleet

  @doc "See `DeviceHost.Fleet.status/0`."
  defdelegate status(), to: DeviceHost.Fleet

  @doc """
  Memory and process accounting for this node, for the runner's sampler.
  """
  @spec memory() :: map()
  def memory do
    %{
      memory: Map.new(:erlang.memory(), fn {k, v} -> {Atom.to_string(k), v} end),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      os_pid: System.pid() |> String.to_integer()
    }
  end
end
