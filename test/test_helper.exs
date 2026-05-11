# Boot a long-lived nerves_hub_web instance for the whole test suite.
# Each test module carves out its own org/product against it.
#
# We need to be a distributed node so the Server module can RPC into
# the running nerves_hub_web instance. The cookie negotiated below is
# also injected into the server via ERL_AFLAGS.
unless Node.alive?() do
  {:ok, _} = Node.start(:"test_nerves_hub@127.0.0.1", :longnames)
  Node.set_cookie(:test_nerves_hub_runner)
end

{:ok, _} = TestNervesHub.Server.start_link()
:ok = TestNervesHub.Server.await_ready()

ExUnit.start(capture_log: true, timeout: :timer.minutes(10))
