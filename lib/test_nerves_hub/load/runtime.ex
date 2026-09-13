defmodule TestNervesHub.Load.Runtime do
  @moduledoc false

  @doc "Make this VM a distributed node, as `test_helper.exs` does for tests."
  @spec ensure_distributed!() :: :ok
  def ensure_distributed! do
    unless Node.alive?() do
      {:ok, _} =
        Node.start(
          :"test_nerves_hub_#{:erlang.unique_integer([:positive])}@127.0.0.1",
          :longnames
        )

      Node.set_cookie(:test_nerves_hub_runner)
    end

    web_port = TestNervesHub.Config.web_port()
    System.put_env("NERVES_HUB_URI", "http://localhost:#{web_port}")
    :ok
  end
end
