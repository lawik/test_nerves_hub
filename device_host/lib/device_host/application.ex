defmodule DeviceHost.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: DeviceHost.FleetSupervisor, max_children: :infinity},
      DeviceHost.Fleet
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DeviceHost.Supervisor)
  end
end
