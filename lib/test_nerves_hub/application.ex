defmodule TestNervesHub.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: TestNervesHub.QEMU.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: TestNervesHub.QEMU.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TestNervesHub.Supervisor)
  end
end
