defmodule TestNervesHub.FirmwareProject do
  @moduledoc """
  Generates a Nerves firmware project on disk using `igniter.new --with nerves.new`
  and installs `nerves_hub_link` via `igniter.install`.

  The result is a Mix project directory ready to be built with `MIX_TARGET=qemu_aarch64`.
  Auth configuration (shared secret or device certificate) is patched into the
  generated `config/target.exs` so the same template can drive either mechanism.
  """

  alias TestNervesHub.Config

  @type auth ::
          {:shared_secret, product_key :: String.t(), product_secret :: String.t()}
          | {:local_cert, cert_pem :: String.t(), key_pem :: String.t()}

  @type opts :: %{
          required(:name) => String.t(),
          required(:auth) => auth(),
          required(:server) => %{
            host: String.t(),
            device_port: pos_integer(),
            ca_pem: String.t() | nil
          },
          optional(:path) => Path.t()
        }

  @doc """
  Generate (or reuse) a firmware project. Returns the absolute project path.

  Idempotent: if the project directory already exists, the generation step is
  skipped and only the config patches are reapplied. That's intentional so a
  test rerun doesn't pay the regeneration cost.
  """
  @spec generate(opts) :: {:ok, Path.t()} | {:error, term()}
  def generate(opts) do
    path = opts[:path] || default_path(opts.name)
    File.mkdir_p!(Path.dirname(path))

    with :ok <- ensure_project(path, opts.name),
         :ok <- ensure_nerves_hub_link(path),
         :ok <- write_ca_cert(path, opts.server),
         :ok <- write_auth_files(path, opts.auth),
         :ok <- patch_target_config(path, opts) do
      {:ok, path}
    end
  end

  defp default_path(name) do
    work_dir = Application.get_env(:test_nerves_hub, :work_dir) || Config.work_dir()
    Path.join([work_dir, "firmware", name])
  end

  defp ensure_project(path, name) do
    if File.exists?(Path.join(path, "mix.exs")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(path))

      args = [
        "igniter.new",
        name,
        "--with",
        "nerves.new",
        "--yes"
      ]

      case run("mix", args, cd: Path.dirname(path)) do
        {_out, 0} -> :ok
        {out, code} -> {:error, {:igniter_new_failed, code, out}}
      end
    end
  end

  defp ensure_nerves_hub_link(path) do
    # `mix igniter.install` will be a no-op if already present.
    case run("mix", ["igniter.install", "nerves_hub_link", "--yes"], cd: path) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:igniter_install_failed, code, out}}
    end
  end

  defp write_ca_cert(_path, %{ca_pem: nil}), do: :ok

  defp write_ca_cert(path, %{ca_pem: pem}) when is_binary(pem) do
    dest = Path.join([path, "priv", "ca.pem"])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, pem)
    :ok
  end

  defp write_auth_files(_path, {:shared_secret, _, _}), do: :ok

  defp write_auth_files(path, {:local_cert, cert_pem, key_pem}) do
    priv = Path.join(path, "priv")
    File.mkdir_p!(priv)
    File.write!(Path.join(priv, "device-cert.pem"), cert_pem)
    File.write!(Path.join(priv, "device-key.pem"), key_pem)
    :ok
  end

  defp patch_target_config(path, opts) do
    config_path = Path.join([path, "config", "target.exs"])
    File.mkdir_p!(Path.dirname(config_path))

    snippet = config_snippet(opts)
    marker = "# >>> test_nerves_hub managed block"
    end_marker = "# <<< test_nerves_hub managed block"

    existing = if File.exists?(config_path), do: File.read!(config_path), else: "import Config\n"

    cleaned =
      Regex.replace(
        ~r/#{Regex.escape(marker)}.*?#{Regex.escape(end_marker)}\n?/s,
        existing,
        ""
      )

    File.write!(config_path, cleaned <> "\n" <> marker <> "\n" <> snippet <> end_marker <> "\n")
    :ok
  end

  defp config_snippet(%{auth: {:shared_secret, key, secret}, server: server}) do
    """
    config :nerves_hub_link,
      configurator: NervesHubLink.Configurator.SharedSecret,
      host: #{inspect(server.host)},
      port: #{server.device_port},
      shared_secret: [
        product_key: #{inspect(key)},
        product_secret: #{inspect(secret)}
      ],
      ssl: [
        cacertfile: "/root/ca.pem",
        verify: :verify_peer,
        server_name_indication: ~c"#{server.host}"
      ]
    """
  end

  defp config_snippet(%{auth: {:local_cert, _, _}, server: server}) do
    """
    config :nerves_hub_link,
      host: #{inspect(server.host)},
      port: #{server.device_port},
      ssl: [
        cacertfile: "/root/ca.pem",
        certfile: "/root/device-cert.pem",
        keyfile: "/root/device-key.pem",
        verify: :verify_peer,
        server_name_indication: ~c"#{server.host}"
      ]
    """
  end

  defp run(cmd, args, opts) do
    System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts)
  end
end
