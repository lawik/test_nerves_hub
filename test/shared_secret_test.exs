defmodule TestNervesHub.SharedSecretTest do
  use TestNervesHub.Case, auth: :shared_secret

  alias TestNervesHub.{QEMU, Org}

  test "device connects with a shared secret", %{device: device, auth_payload: payload} do
    assert is_binary(payload.product_key)
    assert is_binary(payload.product_secret)

    assert {:ok, true} =
             QEMU.eval(
               device,
               "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
             )

    # Pull the device's identifier from the running firmware, then poll
    # both ends — the device's NervesHubLink and the server's record.
    {:ok, identifier} = QEMU.eval(device, "Nerves.Runtime.serial_number()")
    assert is_binary(identifier)

    result =
      wait_until(
        fn ->
          case QEMU.eval(device, "NervesHubLink.connected?()") do
            {:ok, true} -> true
            _ -> false
          end
        end,
        60_000,
        :no_flunk
      )

    if result != :ok do
      diag =
        QEMU.eval(
          device,
          "{Application.get_all_env(:nerves_hub_link), VintageNet.get_configuration(\"eth0\")}"
        )

      # The full Slipstream state is enormous (TLS context etc.). Pull a
      # short summary keyed off whatever fields are present.
      socket_state =
        QEMU.eval(
          device,
          """
          case Process.whereis(NervesHubLink.Socket) do
            nil -> :not_started
            pid ->
              s = :sys.get_state(pid)
              %{
                assigns_keys: Map.keys(s.assigns),
                connected_at: s.assigns[:connected_at],
                joined_at: s.assigns[:joined_at]
              }
          end
          """,
          30_000
        )

      tcp_probe =
        QEMU.eval(
          device,
          ~s|:gen_tcp.connect(~c"10.0.2.2", 4901, [active: false], 5000)|
        )

      ring_log =
        QEMU.eval(
          device,
          """
          RingLogger.get()
          |> Enum.take(-60)
          |> Enum.map(fn entry -> %{level: entry.level, message: to_string(entry.message)} end)
          """,
          30_000
        )

      flunk("""
      Device never reported NervesHubLink.connected?() == true.
      App env + net cfg: #{inspect(diag, pretty: true, limit: :infinity)}
      Socket state: #{inspect(socket_state, pretty: true, limit: 30)}
      TCP probe to device endpoint: #{inspect(tcp_probe, pretty: true)}
      Last 40 ring log entries: #{inspect(ring_log, pretty: true, limit: :infinity, printable_limit: :infinity)}
      """)
    end

    wait_until(fn -> Org.online?(identifier) end, 30_000)
  end

  defp wait_until(fun, timeout, on_timeout \\ :flunk) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_until(fun, deadline, on_timeout)
  end

  defp loop_until(fun, deadline, on_timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        case on_timeout do
          :flunk -> flunk("Condition never became true within timeout")
          :no_flunk -> :timeout
        end
      else
        Process.sleep(500)
        loop_until(fun, deadline, on_timeout)
      end
    end
  end
end
