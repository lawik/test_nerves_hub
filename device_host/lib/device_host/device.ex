defmodule DeviceHost.Device do
  @moduledoc """
  One virtual device: a `NervesHubLink.Supervisor` running as its own
  instance, configured from a spec the runner hands over.

  A spec is a map with:

    * `:index` — integer, unique on this node; doubles as the instance
    * `:identifier` — the device identifier NervesHub will see
    * `:product_key` / `:product_secret` — the product's shared secret
    * `:host` — `"wss://host:port"` of the device endpoint
    * `:sni` — hostname the server's certificate is issued for
    * `:cacerts` — PEM the device trusts for that certificate
    * `:firmware` — map of `nerves_fw_*` values, e.g. from a `.fw` file's
      metadata; `"nerves_fw_uuid"` and `"nerves_fw_product"` matter most
    * `:serializer` — `:json` (default) or `:msgpack`
    * `:compress` — websocket compression, default `true` as on a device
  """

  alias NervesHubLink.Configurator
  alias NervesHubLink.Instance

  @type spec :: %{
          required(:index) => non_neg_integer(),
          required(:identifier) => String.t(),
          required(:product_key) => String.t(),
          required(:product_secret) => String.t(),
          required(:host) => String.t(),
          required(:sni) => String.t(),
          required(:cacerts) => String.t(),
          required(:firmware) => %{String.t() => String.t()},
          optional(:serializer) => :json | :msgpack,
          optional(:compress) => boolean()
        }

  @doc "Child spec for the device's supervision tree."
  @spec child_spec(spec()) :: Supervisor.child_spec()
  def child_spec(%{index: index} = spec) do
    Supervisor.child_spec(
      {NervesHubLink.Supervisor, config: config(spec), name: supervisor_name(index)},
      id: {:device, index},
      restart: :transient
    )
  end

  @doc "The registered name of the device's supervisor."
  @spec supervisor_name(non_neg_integer()) :: GenServer.name()
  def supervisor_name(index), do: Instance.name(NervesHubLink.Supervisor, index)

  @doc "The registered name of the device's socket."
  @spec socket_name(non_neg_integer()) :: GenServer.name()
  def socket_name(index), do: Instance.name(NervesHubLink.Socket, index)

  @doc """
  The `NervesHubLink.Configurator.Config` for a spec.

  Built the way a device builds its own — through the shared-secret
  configurator, so the identifier is signed into the connect headers —
  with the device-specific values layered in as overrides.
  """
  @spec config(spec()) :: Configurator.Config.t()
  def config(spec) do
    cacerts =
      spec.cacerts
      |> :public_key.pem_decode()
      |> Enum.map(fn {_, der, _} -> der end)

    Configurator.build(
      instance: spec.index,
      host: spec.host,
      shared_secret: [
        product_key: spec.product_key,
        product_secret: spec.product_secret,
        identifier: spec.identifier
      ],
      ssl: [
        cacerts: cacerts,
        verify: :verify_peer,
        server_name_indication: to_charlist(spec.sni)
      ],
      params: spec.firmware,
      serializer: Map.get(spec, :serializer, :json),
      compress: Map.get(spec, :compress, true),
      data_path: data_path(spec.index),
      # A real path fwup can write to when an update arrives: the disk
      # image of a device that does not exist.
      fwup_devpath: Path.join(data_path(spec.index), "disk.img"),
      remote_iex: false,
      connect_wait_for_network: false
    )
  end

  @doc "Where a device keeps files it downloads."
  @spec data_path(non_neg_integer()) :: Path.t()
  def data_path(index) do
    root = System.get_env("DEVICE_HOST_DATA_DIR", Path.join(System.tmp_dir!(), "device_host"))
    Path.join(root, Integer.to_string(index))
  end
end
