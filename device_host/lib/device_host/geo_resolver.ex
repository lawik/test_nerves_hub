defmodule DeviceHost.GeoResolver do
  @moduledoc """
  Answers NervesHub's location requests without a network lookup.

  Each instance gets a stable point somewhere in the Nordics, derived from
  its index, so the map view has something to draw and the geo extension's
  server-side path is exercised.
  """

  @behaviour NervesHubLink.Extensions.Geo.Resolver

  @impl true
  def resolve_location do
    index =
      case NervesHubLink.Instance.current() do
        i when is_integer(i) -> i
        _ -> 0
      end

    {:ok,
     %{
       latitude: 55.0 + rem(index * 7, 1500) / 100,
       longitude: 10.0 + rem(index * 13, 2000) / 100,
       source: "device_host",
       accuracy: 500
     }}
  end
end
