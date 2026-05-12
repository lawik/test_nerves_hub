defmodule TestNervesHub.Org do
  @moduledoc """
  Bootstraps user/org/token/key/product/shared_secret fixtures for a
  test module.

  Where possible, this module talks to nerves_hub_web through
  `NervesHubCLI.API` so the test exercises the same HTTP surface
  real users hit and a regression in the CLI or in the JSON API
  controllers becomes a test failure.

  RPC is reserved for operations the public API doesn't expose:

    * `NervesHub.Accounts.create_user/1` — no `/users/register` route.
    * `NervesHub.Accounts.create_org/2` — no org-create API endpoint.
    * `NervesHub.Products.create_shared_secret_auth/1` — no API.
    * `NervesHub.Products.get_product_by_org_id_and_name!/2` — used
      only to recover the product's numeric `id` (the API's product
      JSON view returns just `name`), so we can pass a real
      `%Product{}` into the shared_secret RPC.

  Everything else (token mint, org key registration, product create,
  device create, device cert upload, online check) goes through the
  CLI's HTTP API.
  """

  alias NervesHubCLI.API
  alias TestNervesHub.{Server, Signing}

  @password "test-password-12345"

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
    # Wall-clock suffix so reruns don't collide on unique constraints
    # (`:erlang.unique_integer/1` resets across BEAM instances).
    unique = System.system_time(:millisecond)
    email = "tnh+#{slug}-#{unique}@example.com"
    org_name = "tnh-#{slug}-#{unique}"
    # The product name must match the firmware project's app name so
    # `nerves_fw_product` metadata resolves to this product on upload.
    product_name = "tnh_#{slug}_#{unique}"
    key_name = "tnh-#{slug}-key-#{unique}"

    # RPC bootstrap — no public API for user or org creation.
    {:ok, user} =
      Server.rpc(NervesHub.Accounts, :create_user, [
        %{
          name: "Test #{slug}",
          email: email,
          password: @password
        }
      ])

    {:ok, org} =
      Server.rpc(NervesHub.Accounts, :create_org, [user, %{name: org_name}])

    # Mint a token by exchanging email/password through the public
    # /users/login endpoint — same path a user would take after the
    # CLI's `nh user login` flow. Exercises Accounts.authenticate/2
    # and create_user_api_token/2 server-side.
    auth = login_for_token!(email, "tnh-#{slug}")

    {:ok, %{public_key: pub_pem, private_key: priv_pem}} = Signing.generate_keypair()

    {:ok, _} = API.Key.create(org.name, key_name, String.trim(pub_pem), auth)

    {:ok, %{"data" => _product_data}} =
      API.Product.create(org.name, product_name, auth)

    # The product JSON view returns only `:name`, so we RPC just this
    # one lookup to recover the numeric id we need for the shared
    # secret RPC. Drop this when the API grows an id field.
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
      api_token: auth.token,
      auth: auth,
      org_key: %{name: key_name, public_key: pub_pem, private_key: priv_pem}
    }
  end

  @doc """
  Mint a shared-secret pair on the product. No public API exposes this,
  so we go through `NervesHub.Products.create_shared_secret_auth/1`.
  """
  @spec create_shared_secret_auth(map()) :: {String.t(), String.t()}
  def create_shared_secret_auth(product) do
    {:ok, auth} = Server.rpc(NervesHub.Products, :create_shared_secret_auth, [product.record])
    {auth.key, auth.secret}
  end

  @doc """
  Provision a device with a freshly-minted certificate, fully through
  the HTTP API: `POST /devices`, then `POST /devices/:id/certificates`.

  Returns `{device_attrs, cert_pem, key_pem}`. The cert + key are the
  device-side credentials (caller bakes them into the firmware).
  """
  @spec create_device_with_cert(fixtures(), String.t()) ::
          {map(), String.t(), String.t()}
  def create_device_with_cert(fixtures, identifier) do
    {cert_pem, key_pem} = Signing.generate_device_cert(identifier)

    {:ok, %{"data" => device_data}} =
      API.Device.create(
        fixtures.org.name,
        fixtures.product.name,
        identifier,
        "tnh local-cert e2e",
        ["e2e"],
        fixtures.auth
      )

    {:ok, _} =
      API.DeviceCertificate.create(
        fixtures.org.name,
        fixtures.product.name,
        identifier,
        cert_pem,
        fixtures.auth
      )

    {device_data, cert_pem, key_pem}
  end

  @doc """
  True once the device is reported as connected by the server.

  Goes through the HTTP API (`GET /devices/:identifier`) so we
  exercise the device JSON view, not just an Ecto query.
  """
  @spec online?(fixtures(), String.t()) :: boolean()
  def online?(fixtures, identifier) when is_binary(identifier) do
    path = API.Device.path(fixtures.org.name, fixtures.product.name, identifier)

    case API.request(:get, path, "", fixtures.auth) do
      {:ok, %{"data" => %{"connection_status" => "connected"}}} -> true
      _ -> false
    end
  end

  defp login_for_token!(email, note) do
    case API.User.login(email, @password, note) do
      {:ok, %{"data" => %{"token" => "nh" <> _ = token}}} ->
        %API.Auth{token: token}

      other ->
        raise "POST /users/login failed: #{inspect(other)}"
    end
  end
end
