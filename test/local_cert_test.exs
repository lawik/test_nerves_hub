defmodule TestNervesHub.LocalCertTest do
  use TestNervesHub.Case, auth: :local_cert

  alias TestNervesHub.{QEMU, Org}

  test "device connects with a local certificate", %{
    device: qemu,
    auth_payload: payload,
    fixtures: fixtures
  } do
    # Firmware has been built with the device cert/key already baked in
    # so the device should authenticate on its first connection attempt.
    # IEx prompt fires before user apps finish starting, so poll instead
    # of asserting once.
    case wait_until(fn -> nerves_hub_link_started?(qemu) end, 60_000, :no_flunk) do
      :ok ->
        :ok

      :timeout ->
        flunk("""
        :nerves_hub_link never appeared in Application.started_applications/0.
        Started apps on device: #{inspect(started_apps(qemu), pretty: true, limit: :infinity)}
        Last 60 ring log entries: #{inspect(ring_log(qemu), pretty: true, limit: :infinity, printable_limit: :infinity)}
        """)
    end

    case wait_until(fn -> Org.online?(fixtures, payload.identifier) end, 60_000, :no_flunk) do
      :ok ->
        :ok

      :timeout ->
        flunk("""
        Device #{payload.identifier} never reported as online to the server.
        NervesHubLink.connected?: #{inspect(QEMU.eval(qemu, "NervesHubLink.connected?()"))}
        Last 60 ring log entries: #{inspect(ring_log(qemu), pretty: true, limit: :infinity, printable_limit: :infinity)}
        """)
    end
  end

  defp nerves_hub_link_started?(qemu) do
    case QEMU.eval(
           qemu,
           "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
         ) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp started_apps(qemu) do
    QEMU.eval(qemu, "Application.started_applications() |> Enum.map(&elem(&1, 0))")
  end

  defp ring_log(qemu) do
    QEMU.eval(
      qemu,
      """
      RingLogger.get()
      |> Enum.take(-60)
      |> Enum.map(fn entry -> %{level: entry.level, message: to_string(entry.message)} end)
      """,
      30_000
    )
  end

  defp wait_until(fun, timeout, on_timeout) do
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
