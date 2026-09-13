defmodule DeviceHost.NetworkIdentity do
  @moduledoc """
  A network identity per virtual device, so the extension has something
  to report and NervesHub something to store.
  """

  @behaviour NervesHubLink.Extensions.NetworkIdentity.Provider

  @impl true
  def identity do
    case NervesHubLink.Instance.current() do
      index when is_integer(index) ->
        {:ok,
         %{
           service: "device_host",
           identifier: "vd-" <> String.pad_leading(Integer.to_string(index), 6, "0"),
           details: %{"node" => Atom.to_string(node())}
         }}

      _ ->
        :unavailable
    end
  end
end
