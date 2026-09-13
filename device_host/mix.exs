defmodule DeviceHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :device_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon, :runtime_tools],
      mod: {DeviceHost.Application, []}
    ]
  end

  # `nerves_hub_link` from the multi-instance branch on lawik's fork by
  # default. `NERVES_HUB_LINK_PATH` points it at a local checkout instead,
  # for hacking on the client and the harness together.
  #
  # vintage_net is deliberately absent: it is an optional dep of
  # nerves_hub_link and, on a host, it takes over the machine's routes.
  defp deps do
    [
      nerves_hub_link_dep(),
      {:jason, "~> 1.4"}
    ]
  end

  defp nerves_hub_link_dep do
    case System.get_env("NERVES_HUB_LINK_PATH") do
      path when is_binary(path) and path != "" ->
        {:nerves_hub_link, path: path}

      _ ->
        {:nerves_hub_link,
         github: System.get_env("NERVES_HUB_LINK_GITHUB", "lawik/nerves_hub_link"),
         branch: System.get_env("NERVES_HUB_LINK_BRANCH", "multi-instance")}
    end
  end
end
