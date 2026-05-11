defmodule TestNervesHub.Case do
  @moduledoc """
  ExUnit case template for nerves_hub end-to-end tests.

  Per test module: creates user/org/product/signing-key/API-token,
  generates a Nerves firmware project, builds v1, signs it, uploads it,
  and creates an active deployment.

  Per test: boots a fresh QEMU running v1 of the firmware and exposes
  `TestNervesHub.QEMU.eval/3` via `context.device`.

  Tests are NOT `async: true` — they share one nerves_hub_web instance
  and we keep test orchestration single-threaded for now.

  Usage:

      defmodule MyDeviceTest do
        use TestNervesHub.Case, auth: :shared_secret

        test "device connects", %{device: device} do
          assert {:ok, true} =
            TestNervesHub.QEMU.eval(device, "NervesHubLink.connected?()")
        end
      end
  """

  use ExUnit.CaseTemplate

  alias TestNervesHub.{Config, Deploy, Firmware, FirmwareProject, Org, QEMU, Server}

  using opts do
    auth = Keyword.get(opts, :auth, :shared_secret)

    quote do
      use ExUnit.Case, async: false

      @tag :e2e
      @tnh_auth unquote(auth)

      setup_all do
        TestNervesHub.Case.module_setup(__MODULE__, @tnh_auth)
      end

      setup context do
        TestNervesHub.Case.test_setup(context)
      end
    end
  end

  @doc false
  def module_setup(module, auth_mode) do
    slug = module |> Module.split() |> List.last() |> Macro.underscore()

    fixtures = Org.setup_module(slug)

    {project_path, fw_path, auth_payload} =
      build_firmware(slug, auth_mode, fixtures)

    {:ok, %{uuid: fw_uuid}} =
      Deploy.publish_firmware(fixtures, fw_path, fixtures.org_key)

    deployment_name = "#{slug}-deployment"

    # Empty tags + empty version condition → deployment matches any device
    # for the product, so a freshly-registered device gets attached without
    # us having to update its row out of band.
    {:ok, _deployment} =
      Deploy.create_and_activate_deployment(fixtures, deployment_name, fw_uuid,
        tags: [],
        version: ""
      )

    [
      slug: slug,
      fixtures: fixtures,
      project_path: project_path,
      firmware: fw_path,
      firmware_uuid: fw_uuid,
      deployment_name: deployment_name,
      auth_mode: auth_mode,
      auth_payload: auth_payload
    ]
  end

  @doc false
  def test_setup(%{firmware: fw, project_path: project_path} = context) do
    {:ok, device} =
      DynamicSupervisor.start_child(
        TestNervesHub.QEMU.Supervisor,
        {QEMU, [firmware: fw, project_path: project_path]}
      )

    :ok = QEMU.await_ready(device)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        QEMU.stop(device)
      catch
        :exit, _ -> :ok
      end
    end)

    Map.put(context, :device, device)
  end

  defp build_firmware(slug, :shared_secret, fixtures) do
    {key, secret} = Org.create_shared_secret_auth(fixtures.product)

    server = %{
      host: "10.0.2.2",
      device_port: Config.device_port(),
      ca_pem: Server.ca_pem()
    }

    {:ok, project_path} =
      FirmwareProject.generate(%{
        name: fixtures.product.name,
        auth: {:shared_secret, key, secret},
        server: server
      })

    {:ok, fw} = Firmware.build(project_path)
    {project_path, fw, %{product_key: key, product_secret: secret}}
  end

  defp build_firmware(slug, :local_cert, fixtures) do
    identifier = "tnh-#{slug}-device-#{:erlang.unique_integer([:positive])}"
    {device, cert_pem, key_pem} = Org.create_device_with_cert(fixtures.product, identifier)

    server = %{
      host: "10.0.2.2",
      device_port: Config.device_port(),
      ca_pem: Server.ca_pem()
    }

    {:ok, project_path} =
      FirmwareProject.generate(%{
        name: fixtures.product.name,
        auth: {:local_cert, cert_pem, key_pem},
        server: server
      })

    {:ok, fw} = Firmware.build(project_path)
    {project_path, fw, %{device: device, identifier: identifier}}
  end
end
