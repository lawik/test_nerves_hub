defmodule TestNervesHub do
  @moduledoc """
  End-to-end test orchestration for nerves_hub_web + nerves_hub_link.

  Tests `use TestNervesHub.Case, auth: :shared_secret | :local_cert`. The
  case template generates a firmware project, builds it for the QEMU
  target, boots it, and lets the test send Elixir snippets to the device
  via `TestNervesHub.QEMU.eval/2`.

  See `TestNervesHub.Case` for the high-level entry point.
  """
end
