defmodule TestNervesHub.FirmwareUpdateTest do
  use TestNervesHub.Case, auth: :shared_secret

  alias NervesHubCLI.API
  alias TestNervesHub.{Deploy, Firmware, QEMU, Server}

  test "ships a new firmware to a connected device", ctx do
    assert {:ok, true} =
             QEMU.eval(
               ctx.device,
               "Application.started_applications() |> Enum.any?(fn {a, _, _} -> a == :nerves_hub_link end)"
             )

    # Wait for the device to register/connect on the server side.
    {:ok, identifier} = QEMU.eval(ctx.device, "Nerves.Runtime.serial_number()")
    wait_until(fn -> device_exists?(ctx.fixtures, identifier) end, 60_000)

    server_view_before = device_snapshot(ctx.fixtures, identifier)
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
      server_view_after = device_snapshot(ctx.fixtures, identifier)
      deps = deployments_snapshot(ctx.fixtures)

      flunk("""
      Device never picked up firmware 0.2.0.
      Server view of device:
      #{inspect(server_view_after, pretty: true, limit: :infinity)}
      Deployments visible to the API:
      #{inspect(deps, pretty: true, limit: :infinity)}
      """)
    end
  end

  # API-first: check device existence by GET'ing it from the device API.
  defp device_exists?(fixtures, identifier) do
    path = API.Device.path(fixtures.org.name, fixtures.product.name, identifier)

    case API.request(:get, path, "", fixtures.auth) do
      {:ok, %{"data" => %{}}} -> true
      _ -> false
    end
  end

  # API-first device snapshot for diagnostics. The device JSON view
  # already exposes everything we want (connection_status, firmware
  # metadata, deployment_group), so we don't need RPC here.
  defp device_snapshot(fixtures, identifier) do
    path = API.Device.path(fixtures.org.name, fixtures.product.name, identifier)

    case API.request(:get, path, "", fixtures.auth) do
      {:ok, %{"data" => data}} -> data
      other -> {:api_error, other}
    end
  end

  # No HTTP API exposes "attach device to deployment", so this stays as
  # an RPC bridge into NervesHub.Devices.update_deployment_group/2.
  # Worth replacing once the API grows the operation.
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

  # API-first deployments listing.
  defp deployments_snapshot(fixtures) do
    case API.Deployment.list(fixtures.org.name, fixtures.product.name, fixtures.auth) do
      {:ok, %{"data" => data}} -> data
      other -> {:api_error, other}
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
