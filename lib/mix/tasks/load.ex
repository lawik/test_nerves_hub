defmodule Mix.Tasks.Load do
  @shortdoc "Connect a fleet of virtual devices to nerves_hub_web and measure it"

  @moduledoc """
  Runs a `TestNervesHub.Load.Scenario` built from `LOAD_*` environment
  variables (see that module for the list) and prints the report.

      LOAD_DEVICES=500 LOAD_DEVICE_NODES=2 LOAD_HOLD=300 mix load

  The web checkout, databases and ports come from the same env vars the
  end-to-end tests use (`NERVES_HUB_WEB_SOURCE`, ...). The report and raw
  samples land under `work/load/<run id>/`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    TestNervesHub.Load.Runtime.ensure_distributed!()

    %{summary: summary, dir: dir} =
      TestNervesHub.Load.Scenario.from_env()
      |> TestNervesHub.Load.run()

    Mix.shell().info(TestNervesHub.Load.Report.to_markdown(summary))
    Mix.shell().info("written to #{dir}")
  end
end

defmodule Mix.Tasks.Load.Compare do
  @shortdoc "Put two load run summaries side by side"

  @moduledoc """
      mix load.compare work/load/<before>/summary.json work/load/<after>/summary.json
  """

  use Mix.Task

  @impl Mix.Task
  def run([a, b]) do
    Mix.Task.run("app.start")
    Mix.shell().info(TestNervesHub.Load.Report.compare(a, b))
  end

  def run(_), do: Mix.raise("usage: mix load.compare <summary.json> <summary.json>")
end
