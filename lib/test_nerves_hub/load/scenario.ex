defmodule TestNervesHub.Load.Scenario do
  @moduledoc """
  What a load run does, as data.

  Every field can be set from the environment (`LOAD_*`), so the same
  scenario runs from `mix load`, from the `:load` ExUnit tests, and from
  CI with nothing but variables changed.

  | Field                  | Env                        | Default | Meaning |
  | ---------------------- | -------------------------- | ------- | ------- |
  | `devices`              | `LOAD_DEVICES`             | 100     | virtual devices in total |
  | `device_hosts`         | `LOAD_DEVICE_HOSTS`        | 1       | BEAM nodes the devices are spread over |
  | `device_nodes`         | `LOAD_DEVICE_NODES`        | 1       | `nerves_hub_web` device-role nodes; `0` connects everything to the API node |
  | `device_node_env`      | `LOAD_DEVICE_NODE_ENV`     | prod    | `MIX_ENV` for the device-role nodes |
  | `ramp_per_second`      | `LOAD_RAMP`                | 25      | device starts per second, across all hosts |
  | `hold_seconds`         | `LOAD_HOLD`                | 120     | how long to sit connected once everything is up |
  | `settle_seconds`       | `LOAD_SETTLE`              | 30      | wait after disconnecting before the last sample |
  | `sample_every_ms`      | `LOAD_SAMPLE_MS`           | 5000    | sampler period |
  | `connect_timeout`      | `LOAD_CONNECT_TIMEOUT`     | 600     | seconds allowed for the whole fleet to connect |
  | `serializer`           | `LOAD_SERIALIZER`          | json    | `json` or `msgpack` |
  | `compress`             | `LOAD_COMPRESS`            | true    | websocket compression on the device side |
  | `health_interval_minutes` | `LOAD_HEALTH_MINUTES`   | 1       | how often device nodes ask for health reports (`FEATURES_HEALTH_INTERVAL_MINUTES`) |
  | `payload_bytes`        | `LOAD_PAYLOAD_BYTES`       | 262144  | size of the fake firmware's payload |
  | `label`                | `LOAD_LABEL`               |         | free text carried into the report (a branch name, say) |
  | `node_env`             | `LOAD_NODE_ENV`            |         | extra environment for the device-role nodes, `KEY=value,KEY=value` — e.g. `DEVICE_WEBSOCKET_COMPRESSION=false` or `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2,MALLOC_CONF=...` |
  """

  @type t :: %__MODULE__{}

  defstruct devices: 100,
            device_hosts: 1,
            device_nodes: 1,
            device_node_env: "prod",
            ramp_per_second: 25,
            hold_seconds: 120,
            settle_seconds: 30,
            sample_every_ms: 5_000,
            connect_timeout: 600,
            serializer: :json,
            compress: true,
            health_interval_minutes: 1,
            payload_bytes: 262_144,
            label: nil,
            node_env: []

  @doc "A scenario from `LOAD_*` environment variables over the defaults."
  @spec from_env(keyword()) :: t()
  def from_env(overrides \\ []) do
    %__MODULE__{
      devices: int("LOAD_DEVICES", 100),
      device_hosts: int("LOAD_DEVICE_HOSTS", 1),
      device_nodes: int("LOAD_DEVICE_NODES", 1),
      device_node_env: System.get_env("LOAD_DEVICE_NODE_ENV", "prod"),
      ramp_per_second: int("LOAD_RAMP", 25),
      hold_seconds: int("LOAD_HOLD", 120),
      settle_seconds: int("LOAD_SETTLE", 30),
      sample_every_ms: int("LOAD_SAMPLE_MS", 5_000),
      connect_timeout: int("LOAD_CONNECT_TIMEOUT", 600),
      serializer: String.to_existing_atom(System.get_env("LOAD_SERIALIZER", "json")),
      compress: System.get_env("LOAD_COMPRESS", "true") == "true",
      health_interval_minutes: int("LOAD_HEALTH_MINUTES", 1),
      payload_bytes: int("LOAD_PAYLOAD_BYTES", 262_144),
      label: System.get_env("LOAD_LABEL"),
      node_env: node_env(System.get_env("LOAD_NODE_ENV", ""))
    }
    |> struct!(overrides)
  end

  # `MALLOC_CONF` values contain colons and commas of their own, so pairs
  # are split on commas only where a `KEY=` follows.
  defp node_env(""), do: []

  defp node_env(spec) do
    ~r/,(?=[A-Z_][A-Z0-9_]*=)/
    |> Regex.split(spec)
    |> Enum.map(fn pair ->
      [key, value] = String.split(pair, "=", parts: 2)
      {key, value}
    end)
  end

  defp int(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end
