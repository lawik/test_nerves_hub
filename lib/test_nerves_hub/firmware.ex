defmodule TestNervesHub.Firmware do
  @moduledoc """
  Builds a firmware artifact for the qemu_aarch64 target inside a previously
  generated firmware project. The target is set via `MIX_TARGET` rather than
  baked into the project, matching the user's preferred workflow.
  """

  alias TestNervesHub.{Config, MixCmd}

  @doc """
  Build firmware. Returns the path to the resulting `.fw` artifact.
  """
  @spec build(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def build(project_path, opts \\ []) do
    target = opts[:target] || Config.qemu_target()
    env = [{"MIX_TARGET", target}, {"MIX_ENV", "dev"}]

    # Hex cache is global; serialize anything that may write to it.
    # See FirmwareProject.with_hex_lock/1.
    TestNervesHub.FirmwareProject.with_hex_lock(fn ->
      with {_, 0} <- MixCmd.run(["deps.get"], cd: project_path, env: env),
           {_, 0} <- MixCmd.run(["firmware"], cd: project_path, env: env),
           {:ok, fw} <- locate_firmware(project_path, target) do
        {:ok, fw}
      else
        {out, code} when is_binary(out) ->
          name = Path.basename(project_path)
          log = TestNervesHub.FirmwareProject.keep_log(name, "mix_firmware", out)
          {:error, {:build_failed, code, log}}

        {:error, _} = err ->
          err
      end
    end)
  end

  defp locate_firmware(project_path, target) do
    candidates =
      Path.wildcard(
        Path.join([project_path, "_build", "#{target}_dev", "nerves", "images", "*.fw"])
      )

    case candidates do
      [fw | _] -> {:ok, fw}
      [] -> {:error, :firmware_not_found}
    end
  end
end
