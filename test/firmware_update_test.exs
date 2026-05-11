defmodule TestNervesHub.FirmwareUpdateTest do
  use TestNervesHub.Case, auth: :shared_secret

  alias TestNervesHub.{Deploy, Firmware, QEMU, Server}

  test "ships a new firmware to a connected device", ctx do
    assert {:ok, true} =
             QEMU.eval(
               ctx.device,
               "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
             )

    # Wait for the device to register/connect on the server side.
    {:ok, identifier} = QEMU.eval(ctx.device, "Nerves.Runtime.serial_number()")
    wait_until(fn -> device_exists?(identifier) end, 60_000)

    server_view_before = device_snapshot(identifier)
    IO.puts("Device row after first connect:\n" <> inspect(server_view_before, pretty: true))

    # Manually attach the device to our deployment. NervesHub's auto-match
    # via `matching_deployment_groups` doesn't pick up devices with nil
    # tags against deployments with empty-list tag conditions, so we set
    # the assignment ourselves rather than fight the matching query.
    :ok = attach_device_to_deployment(identifier, ctx.deployment_name, ctx.fixtures)

    bump_firmware_version(ctx.project_path, "0.2.0")
    {:ok, fw2} = Firmware.build(ctx.project_path)

    {:ok, %{uuid: fw2_uuid}} = Deploy.publish_firmware(ctx.fixtures, fw2, ctx.fixtures.org_key)
    {:ok, _} = Deploy.update_deployment_firmware(ctx.fixtures, ctx.deployment_name, fw2_uuid)

    result =
      wait_until(
        fn ->
          case QEMU.eval(ctx.device, "Nerves.Runtime.KV.get(\"nerves_fw_version\")") do
            {:ok, "0.2.0"} -> true
            _ -> false
          end
        end,
        :timer.minutes(2),
        :no_flunk
      )

    if result != :ok do
      server_view_after = device_snapshot(identifier)

      flunk("""
      Device never picked up firmware 0.2.0.
      Server view of device:
      #{inspect(server_view_after, pretty: true, limit: :infinity)}
      """)
    end
  end

  defp device_exists?(identifier) do
    code = """
    try do
      NervesHub.Devices.get_by_identifier!(#{inspect(identifier)})
      true
    rescue
      Ecto.NoResultsError -> false
    end
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {true, _} -> true
      _ -> false
    end
  end

  defp device_snapshot(identifier) do
    code = """
    try do
      d = NervesHub.Devices.get_by_identifier!(#{inspect(identifier)})
      %{
        id: d.id,
        identifier: d.identifier,
        tags: d.tags,
        product_id: d.product_id,
        deployment_id: d.deployment_id,
        connection_status: case d.latest_connection do
          %{status: s} -> s
          _ -> nil
        end,
        firmware_uuid: d.firmware_metadata && d.firmware_metadata.uuid,
        firmware_version: d.firmware_metadata && d.firmware_metadata.version
      }
    rescue
      _ -> :not_found
    end
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {result, _} -> result
      other -> {:rpc_error, other}
    end
  end

  defp attach_device_to_deployment(identifier, deployment_name, fixtures) do
    code = """
    device = NervesHub.Devices.get_by_identifier!(#{inspect(identifier)})

    dep =
      NervesHub.Repo.get_by!(
        NervesHub.ManagedDeployments.DeploymentGroup,
        name: #{inspect(deployment_name)},
        product_id: #{fixtures.product.id}
      )

    NervesHub.Devices.update_deployment_group(device, dep)
    :ok
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {:ok, _} -> :ok
      {result, _} -> result
      other -> {:rpc_error, other}
    end
  end

  defp deployments_snapshot(product_id) do
    code = """
    NervesHub.ManagedDeployments.DeploymentGroup
    |> NervesHub.Repo.all()
    |> Enum.filter(fn d -> d.product_id == #{product_id} end)
    |> Enum.map(fn d ->
      %{id: d.id, name: d.name, platform: d.platform, architecture: d.architecture,
        conditions: d.conditions, is_active: d.is_active,
        current_deployment_release_id: d.current_deployment_release_id}
    end)
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {result, _} -> result
      other -> {:rpc_error, other}
    end
  end

  defp matching_deployments_snapshot(identifier) do
    code = """
    device = NervesHub.Devices.get_by_identifier!(#{inspect(identifier)})
    NervesHub.ManagedDeployments.matching_deployment_groups(device, [true])
    |> Enum.map(fn d -> %{id: d.id, name: d.name, platform: d.platform} end)
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {result, _} -> result
      other -> {:rpc_error, other}
    end
  end

  # Bumping the project's mix.exs version in place is the lightest way
  # to produce a "new" firmware that nerves_hub_web will treat as a
  # distinct release. The version lives in the project/0 function.
  defp bump_firmware_version(project_path, version) do
    mix_exs = Path.join(project_path, "mix.exs")
    contents = File.read!(mix_exs)

    updated =
      Regex.replace(
        ~r/version:\s*"[^"]+"/,
        contents,
        ~s|version: "#{version}"|,
        global: false
      )

    File.write!(mix_exs, updated)
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
        Process.sleep(1_000)
        loop_until(fun, deadline, on_timeout)
      end
    end
  end
end
