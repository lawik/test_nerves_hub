import Config

# The host owns every connection's lifecycle: nothing starts on boot, the
# runner asks `DeviceHost.Fleet` for devices over Erlang distribution.
config :nerves_hub_link,
  start: :manual,
  configurator: NervesHubLink.Configurator.SharedSecret,
  client: DeviceHost.Client,
  # Geo would otherwise call out to whenwhere.nerves-project.org once per
  # device; the fake resolver answers from a seed instead.
  geo: [resolver: DeviceHost.GeoResolver],
  network_identity: [providers: [DeviceHost.NetworkIdentity]],
  # Anything the socket asks the KV for (fwup devpath, firmware metadata)
  # is overridden per device in `DeviceHost.Device.config/1`.
  fwup_devpath: "/dev/null",
  remote_iex: false,
  connect_wait_for_network: false

# On a host `Nerves.Runtime.KV` has no U-Boot environment to read. Give it
# the shape of a validated slot-A firmware so `firmware_valid?/0` and
# `KV.get_all_active/0` behave as they would on a device; the per-device
# values are layered over the top by `NervesHubLink.Configurator.build/1`.
config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "nerves_fw_validated" => "1",
       "nerves_fw_devpath" => "/dev/null",
       "a.nerves_fw_uuid" => "00000000-0000-0000-0000-000000000000",
       "a.nerves_fw_product" => "device_host",
       "a.nerves_fw_version" => "0.0.0",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_architecture" => "x86_64"
     }}

# Host-only noise from nerves_hub_link's runtime deps: no ntpd to run, and
# udevd already owns the input devices.
config :nerves_time, servers: []
config :nerves_uevent, manage_udev: false

config :logger, level: String.to_atom(System.get_env("DEVICE_HOST_LOG_LEVEL", "warning"))
