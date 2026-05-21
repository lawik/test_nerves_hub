defmodule TestNervesHub.DeploymentReleaseApiTest do
  @moduledoc """
  Captures the scenario reported in
  https://github.com/nerves-hub/nerves_hub_web/issues/2654.

  A CI pipeline wants to advance a Managed Deployment Group to a
  new firmware release using only the public CLI / HTTP API surface:

      nh deployment update <name> firmware <firmware_uuid>

  which the CLI sends as

      PUT /orgs/:org/products/:product/deployments/:name
      { "deployment": { "firmware": "<uuid>" } }

  The reporter observed that the endpoint returns success but the
  deployment group's `current_release` is not advanced — no new
  `DeploymentRelease` row is created — so the device is never offered
  the update. Manually creating the release in the Hosted NervesHub UI
  works.

  This test exercises only the public API (no `Code.eval_string` /
  RPC workarounds into NervesHub contexts) so the failure mode is the
  one from the bug report: the deployment listing still reports the
  previous firmware UUID after the update call.
  """

  use TestNervesHub.Case, auth: :shared_secret

  alias NervesHubCLI.API
  alias TestNervesHub.{Deploy, Firmware}

  test "advancing a deployment via the public API moves current_release to the new firmware",
       ctx do
    # Pre-state: the module fixture left the deployment pointing at v1.
    initial = fetch_deployment!(ctx.fixtures, ctx.deployment_name)
    assert initial["firmware_uuid"] == ctx.firmware_uuid

    # Build and publish a v2 firmware via the same public path CI uses.
    bump_firmware_version(ctx.project_path, "0.2.0")
    {:ok, fw2} = Firmware.build(ctx.project_path)

    {:ok, %{uuid: fw2_uuid}} =
      Deploy.publish_firmware(ctx.fixtures, fw2, ctx.fixtures.org_key)

    refute fw2_uuid == ctx.firmware_uuid

    # Exactly the request `nh deployment update <name> firmware <uuid>` sends.
    update_result =
      API.Deployment.update(
        ctx.fixtures.org.name,
        ctx.fixtures.product.name,
        ctx.deployment_name,
        %{firmware: fw2_uuid},
        ctx.fixtures.auth
      )

    assert {:ok, %{"data" => updated}} = update_result

    # The PUT response should already reflect the new firmware UUID.
    assert updated["firmware_uuid"] == fw2_uuid, """
    PUT /deployments/#{ctx.deployment_name} returned 200 but the response
    body still reports the previous firmware UUID.

    Expected firmware_uuid: #{fw2_uuid}
    Got firmware_uuid:      #{inspect(updated["firmware_uuid"])}

    Full response:
    #{inspect(updated, pretty: true, limit: :infinity)}

    See: https://github.com/nerves-hub/nerves_hub_web/issues/2654
    """

    # And a subsequent listing should report the same — i.e. a new
    # DeploymentRelease row was created and is now the current one.
    after_update = fetch_deployment!(ctx.fixtures, ctx.deployment_name)

    assert after_update["firmware_uuid"] == fw2_uuid, """
    GET /deployments still reports the previous firmware after the
    update call, which means no new DeploymentRelease was created on
    the deployment group.

    Expected firmware_uuid: #{fw2_uuid}
    Got firmware_uuid:      #{inspect(after_update["firmware_uuid"])}

    Full deployment row:
    #{inspect(after_update, pretty: true, limit: :infinity)}

    See: https://github.com/nerves-hub/nerves_hub_web/issues/2654
    """

    # current_release.firmware.uuid is the nested field the UI's
    # release-history table reads from; check it too so a partial fix
    # (top-level firmware_uuid moves but nested release does not) is
    # caught explicitly.
    assert get_in(after_update, ["current_release", "firmware", "uuid"]) == fw2_uuid
  end

  defp fetch_deployment!(fixtures, name) do
    {:ok, %{"data" => deployments}} =
      API.Deployment.list(fixtures.org.name, fixtures.product.name, fixtures.auth)

    Enum.find(deployments, fn d -> d["name"] == name end) ||
      flunk("Deployment #{inspect(name)} not present in API list response")
  end

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
end
