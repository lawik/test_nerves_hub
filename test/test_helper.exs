unless Node.alive?() do
  {:ok, _} = Node.start(:"test_nerves_hub@127.0.0.1", :longnames)
  Node.set_cookie(:test_nerves_hub_runner)
end

# Point nerves_hub_cli at the local nerves_hub_web instance.
web_port = Application.get_env(:test_nerves_hub, :web_port, 4900)
System.put_env("NERVES_HUB_URI", "http://localhost:#{web_port}")

{:ok, _} = TestNervesHub.Server.start_link()
:ok = TestNervesHub.Server.await_ready()

ExUnit.start(capture_log: true, timeout: :timer.minutes(10))
