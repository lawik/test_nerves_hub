defmodule TestNervesHub.Signing do
  @moduledoc """
  Generates fwup keypairs and signs firmware artifacts. Mirrors the
  flow that `nh firmware sign` uses in `nerves_hub_cli` so the resulting
  `.fw` is acceptable to nerves_hub_web's signature verification.
  """

  alias TestNervesHub.Config

  @doc """
  Generate a fwup keypair and return their PEM contents.

  fwup's `-g` writes `fwup-key.pub` / `fwup-key.priv` in the cwd. We
  generate into a tmp dir, read the files back, then clean up.
  """
  @spec generate_keypair() :: {:ok, %{public_key: String.t(), private_key: String.t()}}
  def generate_keypair do
    tmp = Path.join([Config.work_dir(), "keys", "tmp-#{:erlang.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)

    try do
      {_, 0} = System.cmd("fwup", ["-g"], cd: tmp, stderr_to_stdout: true)
      pub = File.read!(Path.join(tmp, "fwup-key.pub"))
      priv = File.read!(Path.join(tmp, "fwup-key.priv"))
      {:ok, %{public_key: pub, private_key: priv}}
    after
      File.rm_rf!(tmp)
    end
  end

  @doc """
  Sign the firmware in-place using the given keypair.

  Passes the PEM contents directly via `--private-key`/`--public-key`
  so we don't have to persist the keys to disk.
  """
  @spec sign(Path.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def sign(firmware_path, public_pem, private_pem) do
    case System.cmd(
           "fwup",
           [
             "--sign",
             "-i",
             firmware_path,
             "-o",
             firmware_path,
             "--private-key",
             private_pem,
             "--public-key",
             public_pem
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:fwup_sign_failed, code, out}}
    end
  end
end
