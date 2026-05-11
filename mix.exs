defmodule TestNervesHub.MixProject do
  use Mix.Project

  def project do
    [
      app: :test_nerves_hub,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {TestNervesHub.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.19"},
      {:nerves_hub_cli, path: "../nerves_hub_cli", runtime: false}
    ]
  end
end
