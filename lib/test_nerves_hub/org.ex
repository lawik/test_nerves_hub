defmodule TestNervesHub.Org do
  @moduledoc """
  Bootstraps user/org/token/key/product/shared_secret fixtures for a test
  module. Everything that nerves_hub_cli's HTTP API can do goes through
  the CLI in `TestNervesHub.Deploy`; the bits the public API doesn't
  expose (user/org/api-token/org_key/shared_secret) go through RPC.
  """

  alias TestNervesHub.{Server, Signing}

  @type fixtures :: %{
          user: map(),
          org: map(),
          product: map(),
          api_token: String.t(),
          auth: struct(),
          org_key: %{name: String.t(), public_key: String.t(), private_key: String.t()}
        }

  @doc """
  Create a fresh user + org + product trio + signing key + API token,
  scoped to a single test module.
  """
  @spec setup_module(String.t()) :: fixtures()
  def setup_module(slug) do
    # Use wall-clock time so suffixes don't collide across `mix test` reruns
    # (which reset `:erlang.unique_integer`).
    unique = System.system_time(:millisecond)
    email = "tnh+#{slug}-#{unique}@example.com"
    org_name = "tnh-#{slug}-#{unique}"
    # The product name must match the firmware project's app name so that
    # `nerves_fw_product` metadata resolves to this product on upload.
    # The firmware project is generated with the same name in Case.module_setup/2.
    product_name = "tnh_#{slug}_#{unique}"
    key_name = "tnh-#{slug}-key-#{unique}"

    {:ok, user} =
      Server.rpc(NervesHub.Accounts, :create_user, [
        %{
          name: "Test #{slug}",
          email: email,
          password: "test-password-12345"
        }
      ])

    {:ok, org} =
      Server.rpc(NervesHub.Accounts, :create_org, [user, %{name: org_name}])

    token = Server.rpc(NervesHub.Accounts, :create_user_api_token, [user, "tnh-#{slug}"])
    auth = %NervesHubCLI.API.Auth{token: token}

    {:ok, %{public_key: pub_pem, private_key: priv_pem}} = Signing.generate_keypair()

    {:ok, _org_key} =
      Server.rpc(NervesHub.Accounts, :create_org_key, [
        %{
          name: key_name,
          org_id: org.id,
          created_by_id: user.id,
          key: String.trim(pub_pem)
        }
      ])

    {:ok, %{"data" => _product_data}} =
      NervesHubCLI.API.Product.create(org.name, product_name, auth)

    # The JSON view only returns `name`; load the full record via RPC
    # so callers (e.g. shared_secret_auth) can use the real struct.
    product_record =
      Server.rpc(NervesHub.Products, :get_product_by_org_id_and_name!, [
        org.id,
        product_name
      ])

    product = %{
      id: product_record.id,
      name: product_record.name,
      org_id: org.id,
      org_name: org.name,
      record: product_record
    }

    %{
      user: user,
      org: org,
      product: product,
      api_token: token,
      auth: auth,
      org_key: %{name: key_name, public_key: pub_pem, private_key: priv_pem}
    }
  end

  @doc """
  Mint a shared-secret pair on the product (NervesHub.Products.SharedSecretAuth).
  Returns `{key, secret}` plaintext.
  """
  @spec create_shared_secret_auth(map()) :: {String.t(), String.t()}
  def create_shared_secret_auth(product) do
    {:ok, auth} = Server.rpc(NervesHub.Products, :create_shared_secret_auth, [product.record])
    {auth.key, auth.secret}
  end

  @doc """
  Create a device row up front (used by local-cert mode) and mint a
  device certificate signed by the product.
  """
  @spec create_device_with_cert(map(), String.t()) :: {map(), String.t(), String.t()}
  def create_device_with_cert(product, identifier) do
    {:ok, device} =
      Server.rpc(NervesHub.Devices, :create_device, [
        %{
          identifier: identifier,
          product_id: product.id,
          org_id: product.org_id,
          tags: ["e2e"]
        }
      ])

    {:ok, %{cert: cert_pem, key: key_pem}} =
      Server.rpc(NervesHub.Devices, :create_device_certificate, [device])

    {device, cert_pem, key_pem}
  end

  @doc "True once the device is reported as connected by the server."
  @spec online?(String.t()) :: boolean()
  def online?(identifier) when is_binary(identifier) do
    # Avoid sending closures over Erlang dist (requires matching beam on
    # both nodes). Instead run a small string of code via Code.eval_string,
    # which is always loaded.
    code = """
    try do
      device = NervesHub.Devices.get_by_identifier!(#{inspect(identifier)})
      case device.latest_connection do
        %{status: :connected} -> true
        _ -> false
      end
    rescue
      Ecto.NoResultsError -> false
    end
    """

    case Server.rpc(Code, :eval_string, [code]) do
      {true, _} -> true
      _ -> false
    end
  end
end
