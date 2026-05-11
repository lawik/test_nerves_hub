import Config

# Defaults can be overridden by environment variables at test time.
# Database names are deliberately namespaced so we don't collide with
# a developer's local nerves_hub_dev / nerves_hub_test databases.
config :test_nerves_hub,
  nerves_hub_web_path:
    System.get_env("NERVES_HUB_WEB_PATH", Path.expand("../nerves_hub_web", __DIR__)),
  work_dir: System.get_env("TEST_NERVES_HUB_WORK_DIR", Path.expand("../work", __DIR__)),
  qemu_target: System.get_env("MIX_TARGET", "qemu_aarch64"),
  postgres: [
    url:
      System.get_env(
        "TEST_NERVES_HUB_DATABASE_URL",
        "postgres://postgres:postgres@localhost/postgres"
      ),
    database: System.get_env("TEST_NERVES_HUB_DATABASE", "test_nerves_hub_e2e")
  ],
  clickhouse: [
    url:
      System.get_env(
        "TEST_NERVES_HUB_CLICKHOUSE_URL",
        "http://default:@localhost:8123/"
      ),
    database: System.get_env("TEST_NERVES_HUB_CLICKHOUSE_DATABASE", "test_nerves_hub_e2e")
  ],
  web_port: String.to_integer(System.get_env("TEST_NERVES_HUB_WEB_PORT", "4900")),
  device_port: String.to_integer(System.get_env("TEST_NERVES_HUB_DEVICE_PORT", "4901"))
