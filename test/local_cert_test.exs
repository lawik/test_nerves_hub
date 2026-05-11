defmodule TestNervesHub.LocalCertTest do
  use TestNervesHub.Case, auth: :local_cert

  alias TestNervesHub.{QEMU, Org}

  test "device connects with a local certificate", %{device: qemu, auth_payload: payload} do
    # Firmware has been built with the device cert/key already baked in
    # so the device should authenticate on its first connection attempt.
    assert {:ok, true} =
             QEMU.eval(
               qemu,
               "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
             )

    wait_until(fn -> Org.online?(payload.device) end)
  end

  defp wait_until(fun, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop_until(fun, deadline)
  end

  defp loop_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("Condition never became true within timeout")
      else
        Process.sleep(500)
        loop_until(fun, deadline)
      end
    end
  end
end
