defmodule TestNervesHub.Load.Firmware do
  @moduledoc """
  A firmware that exists only to be reported and downloaded.

  A load run needs a `Firmware` row for the product so that a device's
  join resolves to known firmware and a deployment group can be created —
  and, in an update scenario, something the devices can download and hand
  to `fwup`. Building a real Nerves firmware for that takes minutes; a
  fwup archive with a payload and an `upgrade` task that writes it takes
  a second. NervesHub never looks inside beyond the metadata.
  """

  alias TestNervesHub.Config

  @doc """
  Build a signed-ready `.fw` under the work dir. Returns
  `{path, params}` where `params` are the `nerves_fw_*` values a device
  running it reports on join.
  """
  @spec build(%{product: String.t(), version: String.t(), payload_bytes: pos_integer()}) ::
          {Path.t(), %{String.t() => String.t()}}
  def build(%{product: product, version: version} = opts) do
    dir = Path.join([Config.work_dir(), "load", "firmware", "#{product}-#{version}"])
    File.mkdir_p!(dir)

    payload = Path.join(dir, "payload.bin")
    File.write!(payload, :crypto.strong_rand_bytes(Map.get(opts, :payload_bytes, 262_144)))

    conf = Path.join(dir, "fwup.conf")

    File.write!(conf, """
    meta-product = "#{product}"
    meta-version = "#{version}"
    meta-platform = "host"
    meta-architecture = "x86_64"
    meta-author = "test_nerves_hub"
    meta-description = "load test firmware"
    meta-misc = "load"

    file-resource payload.bin {
      host-path = "#{payload}"
    }

    task upgrade {
      on-resource payload.bin { raw_write(0) }
    }

    task complete {
      on-resource payload.bin { raw_write(0) }
    }
    """)

    fw = Path.join(dir, "#{product}-#{version}.fw")

    case System.cmd("fwup", ["-c", "-q", "-f", conf, "-o", fw], stderr_to_stdout: true) do
      {_, 0} -> {fw, params(fw)}
      {out, code} -> raise "fwup -c failed (#{code}):\n#{out}"
    end
  end

  @doc """
  The join params for a device running `fw`: fwup's `meta-*` keys as the
  `nerves_fw_*` values a Nerves device reads out of its U-Boot env.
  """
  @spec params(Path.t()) :: %{String.t() => String.t()}
  def params(fw) do
    {out, 0} = System.cmd("fwup", ["-m", "-i", fw], stderr_to_stdout: true)

    for line <- String.split(out, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        String.starts_with?(key, "meta-"),
        into: %{} do
      {"nerves_fw_" <> String.replace(String.trim_leading(key, "meta-"), "-", "_"),
       String.trim(value, "\"")}
    end
  end
end
