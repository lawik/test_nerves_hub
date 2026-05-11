defmodule TestNervesHub.Case do
  @moduledoc """
  ExUnit case template for nerves_hub end-to-end tests.

  Each test *module* gets its own user/org/product so tests can poke at
  the server without stepping on each other. The firmware project is
  generated once per module (auth mode is fixed at `use`-time) and the
  resulting `.fw` is reused across the module's tests; a fresh QEMU
  instance is booted per test.

  Tests are NOT `async: true` — they share a single nerves_hub_web
  instance and orchestrating QEMU instances in parallel is more pain
  than reward for now.

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

  alias TestNervesHub.{FirmwareProject, Firmware, QEMU, Org, Server, Config}

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

    %{user: user, org: org, product: product} = Org.setup_module(slug)

    {project_path, fw_path, auth_payload} = build_firmware(slug, auth_mode, user, product)

    on_exit(fn -> :ok end)

    [
      slug: slug,
      user: user,
      org: org,
      product: product,
      project_path: project_path,
      firmware: fw_path,
      auth_mode: auth_mode,
      auth_payload: auth_payload
    ]
  end

  @doc false
  def test_setup(%{firmware: fw, project_path: project_path} = context) do
    {:ok, device} =
      DynamicSupervisor.start_child(TestNervesHub.QEMU.Supervisor, {
        QEMU,
        firmware: fw, project_path: project_path
      })

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

  defp build_firmware(slug, :shared_secret, user, product) do
    {key, secret} = Org.create_shared_secret_auth(user, product)

    server = %{
      host: "10.0.2.2",
      device_port: Config.device_port(),
      ca_pem: Server.ca_pem()
    }

    {:ok, project_path} =
      FirmwareProject.generate(%{
        name: "tnh_#{slug}",
        auth: {:shared_secret, key, secret},
        server: server
      })

    {:ok, fw} = Firmware.build(project_path)
    {project_path, fw, %{product_key: key, product_secret: secret}}
  end

  defp build_firmware(slug, :local_cert, _user, product) do
    identifier = "tnh-#{slug}-device-#{:erlang.unique_integer([:positive])}"
    {device, cert_pem, key_pem} = Org.create_device_with_cert(product, identifier)

    server = %{
      host: "10.0.2.2",
      device_port: Config.device_port(),
      ca_pem: Server.ca_pem()
    }

    {:ok, project_path} =
      FirmwareProject.generate(%{
        name: "tnh_#{slug}",
        auth: {:local_cert, cert_pem, key_pem},
        server: server
      })

    {:ok, fw} = Firmware.build(project_path)
    {project_path, fw, %{device: device, identifier: identifier}}
  end
end
