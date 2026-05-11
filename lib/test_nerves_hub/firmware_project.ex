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
    # `NERVES_HUB_LINK_PACKAGE` lets a developer point the firmware at a
    # local checkout or a feature branch by passing igniter's native
    # `package@git:`, `package@github:`, or `package@path:` syntax. The
    # default hex install becomes the bare `nerves_hub_link` spec.
    package = Config.nerves_hub_link_package()

    case run("mix", ["igniter.install", package, "--yes", "--yes-to-deps"], cd: path) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:igniter_install_failed, code, out}}
    end
  end

  defp write_auth_files(_path, _auth), do: :ok

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

  # nerves_hub_web's dev/test fixtures ship a server cert for the hostname
  # below. SNI must match so peer verification succeeds even though the
  # underlying network connection is to an IP (10.0.2.2 in QEMU user-mode
  # networking).
  @server_cert_hostname "device.nerves-hub.org"

  # NervesHubLink builds the websocket URL from `:host` and only consults
  # `:port` for `device_api_*` style config. We embed scheme+port directly
  # into `:host` so the resulting URL carries the right port (otherwise
  # the device probes 10.0.2.2:443 and the connection never lifts off).
  #
  # We embed the CA / device cert PEMs directly in the config rather than
  # writing them to the rootfs because SharedSecret.build/1 does
  # `Keyword.put_new(:cacerts, default_certs)` — if we use `:cacertfile`
  # our file is silently ignored and TLS fails with "Unknown CA". Setting
  # `:cacerts` explicitly keeps SharedSecret's put_new a no-op.
  defp config_snippet(%{auth: {:shared_secret, key, secret}, server: server}) do
    cacerts_literal = ca_pem_to_cacerts_literal(server.ca_pem)

    """
    __tnh_cacerts = #{cacerts_literal}

    config :nerves_hub_link,
      configurator: NervesHubLink.Configurator.SharedSecret,
      host: "wss://#{server.host}:#{server.device_port}",
      shared_secret: [
        product_key: #{inspect(key)},
        product_secret: #{inspect(secret)}
      ],
      ssl: [
        cacerts: __tnh_cacerts,
        verify: :verify_peer,
        server_name_indication: ~c"#{@server_cert_hostname}"
      ]
    """
  end

  defp config_snippet(%{auth: {:local_cert, cert_pem, key_pem}, server: server}) do
    cacerts_literal = ca_pem_to_cacerts_literal(server.ca_pem)
    cert_der_literal = pem_to_der_literal(cert_pem)
    key_der_literal = key_pem_to_der_literal(key_pem)

    """
    __tnh_cacerts = #{cacerts_literal}
    __tnh_cert = #{cert_der_literal}
    __tnh_key = #{key_der_literal}

    config :nerves_hub_link,
      host: "wss://#{server.host}:#{server.device_port}",
      ssl: [
        cacerts: __tnh_cacerts,
        cert: __tnh_cert,
        key: __tnh_key,
        verify: :verify_peer,
        server_name_indication: ~c"#{@server_cert_hostname}"
      ]
    """
  end

  # Pre-decode PEMs at firmware-project-generation time so the literal we
  # splice into target.exs is just bytes — no file IO at runtime on the
  # device, and the SharedSecret default-cacerts merge can't clobber us.
  defp ca_pem_to_cacerts_literal(pem) when is_binary(pem) do
    pem
    |> :public_key.pem_decode()
    |> Enum.map(fn {_, der, _} -> der end)
    |> inspect(limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)
  end

  defp pem_to_der_literal(pem) when is_binary(pem) do
    [{_, der, _} | _] = :public_key.pem_decode(pem)
    inspect(der, limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)
  end

  defp key_pem_to_der_literal(pem) when is_binary(pem) do
    [{type, der, _} | _] = :public_key.pem_decode(pem)
    # Erlang's ssl :key option wants `{type, der}`
    inspect({type, der}, limit: :infinity, printable_limit: :infinity, binaries: :as_binaries)
  end

  defp run(cmd, args, opts) do
    System.cmd(cmd, args, [stderr_to_stdout: true] ++ opts)
  end
end
