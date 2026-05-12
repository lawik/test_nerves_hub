# test_nerves_hub

End-to-end test orchestration for [nerves_hub_web], [nerves_hub_link], and
[nerves_hub_cli]. Each test boots a real Nerves firmware in QEMU, connects it
to a locally-managed `nerves_hub_web` instance, and verifies the full
device/server interaction — firmware upload, deployment, the WebSocket join,
etc.

The runner generates a fresh firmware project per test module via
`mix igniter.new --with nerves.new` and `mix igniter.install nerves_hub_link`,
so no firmware project is vendored in this repo.

## Prerequisites

System tools (on `$PATH`):

* `mix` (Elixir 1.19+, Erlang/OTP 28+)
* `qemu-system-aarch64`
* `fwup`
* `git`

Running services:

* Postgres reachable at the URL in `TEST_NERVES_HUB_DATABASE_URL`
  (default `postgres://postgres:postgres@localhost/postgres`).
* ClickHouse HTTP interface at `TEST_NERVES_HUB_CLICKHOUSE_URL`
  (default `http://default:@localhost:8123/`).

A `docker-compose.yml` for both lives in the [nerves_hub_web repo].

## Quickstart

```sh
git clone https://github.com/<you>/test_nerves_hub.git
cd test_nerves_hub
# Install the igniter_new and nerves_bootstrap archives into the Elixir
# install that the project's `.tool-versions` selects. Run them after
# `cd` so any asdf-style version switch is already applied.
mix archive.install hex igniter_new
mix archive.install hex nerves_bootstrap
mix deps.get
mix test
```

With no env vars, the runner will:

1. Clone `nerves-hub/nerves_hub_web` from GitHub (main branch) into
   `work/nerves_hub_web/`.
2. Start the NervesHub server on ports 4900 (web) / 4901 (device).
3. For each test module: generate a fresh firmware project under
   `work/firmware/<slug>_<ts>/`, install the latest hex
   `nerves_hub_link`, build firmware, sign it, upload it, create a
   deployment.
4. For each test: boot QEMU with a random per-instance MAC, attach the
   serial console to a Port, and run the test body.

Expect the first run to take 5–15 minutes (clone + deps + Nerves system
+ first firmware build). Subsequent runs reuse most of that.

## Configuration

All knobs are env vars. Database names default to `test_nerves_hub_e2e`
so they don't collide with a developer's local `nerves_hub_dev` /
`nerves_hub_test`.

| Env var                              | Default                                              | Meaning |
| ------------------------------------ | ---------------------------------------------------- | ------- |
| `NERVES_HUB_WEB_SOURCE`              | `https://github.com/nerves-hub/nerves_hub_web.git`   | Local directory **or** git URL (https / ssh / `user@host:path`). |
| `NERVES_HUB_WEB_REF`                 | `main`                                               | Branch / tag / commit, only relevant when the source is a git URL. |
| `NERVES_HUB_LINK_PACKAGE`            | `nerves_hub_link`                                    | Package spec passed verbatim to `mix igniter.install`. |
| `TEST_NERVES_HUB_DATABASE_URL`       | `postgres://postgres:postgres@localhost/postgres`    | Postgres connection (the database in the URL only has to exist; the runner creates the test DB itself). |
| `TEST_NERVES_HUB_DATABASE`           | `test_nerves_hub_e2e`                                | Postgres database the test suite uses. |
| `TEST_NERVES_HUB_CLICKHOUSE_URL`     | `http://default:@localhost:8123/`                    | ClickHouse HTTP endpoint. |
| `TEST_NERVES_HUB_CLICKHOUSE_DATABASE`| `test_nerves_hub_e2e`                                | ClickHouse database the test suite uses. |
| `TEST_NERVES_HUB_WEB_PORT`           | `4900`                                               | Web endpoint port. |
| `TEST_NERVES_HUB_DEVICE_PORT`        | `4901`                                               | Device endpoint port (usually `web_port + 1`). |
| `TEST_NERVES_HUB_WORK_DIR`           | `<repo>/work`                                        | Where clones, firmware projects, and logs live. |

### Examples

```sh
# Point web at a local checkout (no clone)
NERVES_HUB_WEB_SOURCE=../nerves_hub_web mix test

# Point web at a feature branch on a fork
NERVES_HUB_WEB_SOURCE=git@github.com:yourname/nerves_hub_web.git \
  NERVES_HUB_WEB_REF=fix-the-thing \
  mix test

# Pin nerves_hub_link to a specific hex version
NERVES_HUB_LINK_PACKAGE='nerves_hub_link@2.10.0' mix test

# Local path checkout of nerves_hub_link
NERVES_HUB_LINK_PACKAGE='nerves_hub_link@path:/abs/path/to/nerves_hub_link' mix test

# GitHub branch of nerves_hub_link
NERVES_HUB_LINK_PACKAGE='nerves_hub_link@github:nerves-hub/nerves_hub_link@main' mix test

# Arbitrary git URL + ref for nerves_hub_link
NERVES_HUB_LINK_PACKAGE='nerves_hub_link@git:https://github.com/forked/nerves_hub_link@some-branch' mix test
```

## Writing a test

```elixir
defmodule MyDevice.SharedSecretTest do
  # auth modes: :shared_secret | :local_cert
  use TestNervesHub.Case, auth: :shared_secret

  alias TestNervesHub.{QEMU, Org}

  test "device comes online", %{device: device} do
    # `device` is a TestNervesHub.QEMU pid for a freshly-booted instance.
    # Evaluate any Elixir expression on the device — the result round-trips
    # back through the serial console:
    assert {:ok, true} = QEMU.eval(device, "NervesHubLink.connected?()")

    {:ok, identifier} = QEMU.eval(device, "Nerves.Runtime.serial_number()")
    assert is_binary(identifier)

    # Org.online?/1 polls nerves_hub_web via Erlang distribution.
    assert Org.online?(identifier)
  end
end
```

### What the case template gives you in `context`

| Key                 | Description                                                                |
| ------------------- | -------------------------------------------------------------------------- |
| `:device`           | `pid` for the running QEMU instance. Pass to `TestNervesHub.QEMU.eval/2`.  |
| `:fixtures`         | Map with `user`, `org`, `product`, `api_token`, `auth`, `org_key`.         |
| `:project_path`     | Absolute path to the generated firmware project (for rebuilds).            |
| `:firmware`         | Path to the current `.fw` artifact.                                        |
| `:firmware_uuid`    | UUID assigned by nerves_hub_web on upload.                                 |
| `:deployment_name`  | Name of the active deployment created for this test module.                |
| `:auth_mode`        | `:shared_secret` or `:local_cert`.                                         |
| `:auth_payload`     | Mode-specific creds — `%{product_key, product_secret}` or `%{device, identifier}`. |

### Shipping a firmware update

```elixir
test "device receives a new firmware", ctx do
  # Bump version, rebuild, sign + upload v2, repoint the deployment.
  patch_mix_version(ctx.project_path, "0.2.0")
  {:ok, fw2} = TestNervesHub.Firmware.build(ctx.project_path)
  {:ok, %{uuid: uuid2}} =
    TestNervesHub.Deploy.publish_firmware(ctx.fixtures, fw2, ctx.fixtures.org_key)
  {:ok, _} =
    TestNervesHub.Deploy.update_deployment_firmware(
      ctx.fixtures,
      ctx.deployment_name,
      uuid2
    )

  wait_until(fn ->
    match?({:ok, "0.2.0"},
      TestNervesHub.QEMU.eval(ctx.device, ~s|Nerves.Runtime.KV.get("nerves_fw_version")|))
  end)
end
```

See `test/firmware_update_test.exs` for the full version.

## How the pieces fit

```
test_helper.exs
  └─ TestNervesHub.Server          # boots nerves_hub_web via mix phx.server
       └─ Erlang dist RPC ──────► nerves_hub_web (NervesHub.* contexts)

TestNervesHub.Case (per module)
  ├─ TestNervesHub.Org              # user / org / api_token / org_key / shared_secret
  ├─ TestNervesHub.FirmwareProject  # mix igniter.new --with nerves.new
  │                                  # mix igniter.install <NERVES_HUB_LINK_PACKAGE>
  │                                  # patches config/target.exs with CA / auth
  ├─ TestNervesHub.Signing          # fwup -g and fwup --sign
  ├─ TestNervesHub.Firmware         # MIX_TARGET=qemu_aarch64 mix firmware
  └─ TestNervesHub.Deploy           # NervesHubCLI.API for upload + deployment

TestNervesHub.Case (per test)
  └─ TestNervesHub.QEMU             # mix nerves.gen.qemu → qemu-system-aarch64
                                     # serial console under a Port
                                     # eval/2 wraps snippets in markers and
                                     # round-trips terms via base64
```

The intent is that you'd notice if `nerves_hub_web`, `nerves_hub_link`, or
`nerves_hub_cli` drifted: test setup goes through their actual public
surfaces (contexts via RPC, HTTP API via the CLI, hex / git installs of
`nerves_hub_link`).

## Troubleshooting

* **Test setup fails with `:undef` for a `NervesHub.*` function** — the
  context API in `nerves_hub_web` changed shape. Update `lib/test_nerves_hub/org.ex`
  or wherever the call lives.
* **Device boots but `NervesHubLink.connected?()` stays false** — check
  `work/nerves_hub_web.log` for the server-side rejection. Common causes:
  TLS hostname mismatch (the `device.nerves-hub.org` SNI must match the
  fixture cert), shared secrets disabled in the server config, duplicate
  device identifier from a stale `devices` row.
* **`mix qemu` not found** — the task is actually `mix nerves.gen.qemu`,
  shipped with `nerves_system_qemu_aarch64`. `TestNervesHub.QEMU` already
  uses the right name; if you see this, you're invoking it manually.
* **Orphaned Phoenix / QEMU processes after a crashed test run** — kill them
  with `pkill -f 'nerves_hub_[0-9]+@'` and `pkill qemu-system-aarch64`.
  The case template's `on_exit` covers normal exits, but a `kill -9`'d
  test runner can leave subprocesses.

## Caveats

* The firmware update test currently times out on the device-side firmware
  install step; the publish + deployment-release path works, but the
  on-device swap needs more orchestrator investigation. See the TODO at the
  bottom of `test/firmware_update_test.exs`.
* Test databases (`test_nerves_hub_e2e`) are reused between runs — rows
  accumulate. Drop them with `psql -c 'drop database test_nerves_hub_e2e'`
  if you want a clean slate.

[nerves_hub_web]: https://github.com/nerves-hub/nerves_hub_web
[nerves_hub_link]: https://github.com/nerves-hub/nerves_hub_link
[nerves_hub_cli]: https://github.com/nerves-hub/nerves_hub_cli
[nerves_hub_web repo]: https://github.com/nerves-hub/nerves_hub_web
