defmodule TestNervesHub.Org do
  @moduledoc """
  Helpers that create the org/product/device fixtures inside the running
  nerves_hub_web instance, via Erlang distribution.

  These call the actual NervesHub.* context modules so we exercise the
  real code path rather than re-implementing schema writes here.
  """

  alias TestNervesHub.Server

  @doc """
  Create a fresh user + org + product trio scoped to a single test module.
  Returns a map of the created records.
  """
  @spec setup_module(String.t()) :: %{
          user: map(),
          org: map(),
          product: map()
        }
  def setup_module(slug) do
    unique = :erlang.unique_integer([:positive])
    email = "tnh+#{slug}-#{unique}@example.com"
    org_name = "tnh-#{slug}-#{unique}"
    product_name = "tnh-#{slug}-product-#{unique}"

    {:ok, user} =
      Server.rpc(NervesHub.Accounts, :create_user, [
        %{
          name: "Test #{slug}",
          email: email,
          password: "test-password-12345"
        }
      ])

    {:ok, org} =
      Server.rpc(NervesHub.Accounts, :create_org, [
        user,
        %{name: org_name}
      ])

    {:ok, product} =
      Server.rpc(NervesHub.Products, :create_product, [
        user,
        %{name: product_name, org_id: org.id}
      ])

    %{user: user, org: org, product: product}
  end

  @doc """
  Generate a shared-secret auth pair for the given product.
  Returns `{product_key, product_secret}` plaintext.
  """
  @spec create_shared_secret_auth(map(), map()) :: {String.t(), String.t()}
  def create_shared_secret_auth(user, product) do
    {:ok, auth} =
      Server.rpc(NervesHub.Products, :create_shared_secret_auth, [user, product])

    {auth.key, auth.secret}
  end

  @doc """
  Pre-create a device row so the firmware can come up and attach to it,
  and mint a device certificate signed by the product's CA.

  Returns `{device, cert_pem, key_pem}`.
  """
  @spec create_device_with_cert(map(), String.t()) ::
          {map(), String.t(), String.t()}
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

  @doc "Returns true once the device is reported online by the server."
  @spec online?(map()) :: boolean()
  def online?(device) do
    case Server.rpc(NervesHub.Devices, :get_device, [device.id]) do
      %{connection_status: :connected} -> true
      _ -> false
    end
  end
end
