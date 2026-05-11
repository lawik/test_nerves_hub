defmodule TestNervesHub.Deploy do
  @moduledoc """
  Uses `nerves_hub_cli`'s HTTP API to upload firmware and manage
  deployments on the running `nerves_hub_web` instance.

  We use the CLI rather than RPC for the firmware/deployment flow on
  purpose — it exercises the same HTTP surface that real users hit, so
  the test catches regressions in API auth and serialization.
  """

  alias NervesHubCLI.API
  alias TestNervesHub.Signing

  @doc """
  Sign and upload a firmware artifact, returning the server-issued uuid.
  """
  @spec publish_firmware(map(), Path.t(), %{
          public_key: String.t(),
          private_key: String.t()
        }) :: {:ok, %{uuid: String.t(), data: map()}} | {:error, term()}
  def publish_firmware(fixtures, fw_path, key) do
    with :ok <- Signing.sign(fw_path, key.public_key, key.private_key),
         {:ok, %{"data" => data}} <-
           API.Firmware.create(
             fixtures.org.name,
             fixtures.product.name,
             fw_path,
             nil,
             fixtures.auth
           ) do
      {:ok, %{uuid: data["uuid"], data: data}}
    end
  end

  @doc """
  Create a deployment pointing at `firmware_uuid` and activate it.

  Tags default to `["e2e"]`; version condition defaults to "" (any).
  """
  @spec create_and_activate_deployment(map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_and_activate_deployment(fixtures, name, firmware_uuid, opts \\ []) do
    version = Keyword.get(opts, :version, "")
    tags = Keyword.get(opts, :tags, ["e2e"])

    with {:ok, _} <-
           API.Deployment.create(
             fixtures.org.name,
             fixtures.product.name,
             name,
             firmware_uuid,
             version,
             tags,
             fixtures.auth
           ),
         {:ok, %{"data" => data}} <-
           API.Deployment.update(
             fixtures.org.name,
             fixtures.product.name,
             name,
             %{is_active: true},
             fixtures.auth
           ) do
      {:ok, data}
    end
  end

  @doc """
  Repoint an existing deployment at a new firmware uuid.

  The CLI's `PUT /deployments/:name` doesn't actually change the active
  firmware — that update path only touches metadata on the deployment
  group. Changing firmware in the new system means creating a fresh
  `DeploymentRelease` row, which has no public REST endpoint. We RPC
  into `ManagedDeployments.create_deployment_release/5` directly.
  """
  @spec update_deployment_firmware(map(), String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def update_deployment_firmware(fixtures, deployment_name, firmware_uuid) do
    code = """
    product = NervesHub.Repo.get!(NervesHub.Products.Product, #{fixtures.product.id})

    dep =
      NervesHub.Repo.get_by!(
        NervesHub.ManagedDeployments.DeploymentGroup,
        name: #{inspect(deployment_name)},
        product_id: product.id
      )

    firmware = NervesHub.Firmwares.get_firmware_by_product_and_uuid!(product, #{inspect(firmware_uuid)})
    user = NervesHub.Repo.get!(NervesHub.Accounts.User, #{fixtures.user.id})

    NervesHub.ManagedDeployments.create_deployment_release(dep, firmware, nil, user, %{})
    """

    case TestNervesHub.Server.rpc(Code, :eval_string, [code]) do
      {{:ok, _release}, _} -> {:ok, :released}
      {result, _} -> {:error, result}
      other -> {:error, other}
    end
  end
end
