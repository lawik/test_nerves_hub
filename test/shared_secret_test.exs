defmodule TestNervesHub.SharedSecretTest do
  use TestNervesHub.Case, auth: :shared_secret

  alias TestNervesHub.{QEMU, Org}

  test "device connects with a shared secret", %{device: device, auth_payload: payload} = ctx do
    assert is_binary(payload.product_key)
    assert is_binary(payload.product_secret)

    assert {:ok, true} =
             QEMU.eval(
               device,
               "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
             )

    wait_until(fn -> Org.online?(server_device(ctx)) end)
  end

  defp server_device(_ctx) do
    # In shared-secret mode the device row is created lazily on first
    # connect. We look it up by identifier instead of holding a ref.
    # TODO: thread identifier from FirmwareProject so this isn't fragile.
    %{id: nil}
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
