defmodule DeviceHost.Client do
  @moduledoc """
  `NervesHubLink.Client` for virtual devices.

  Accepts every update NervesHub offers, so an update scenario exercises
  the whole download-and-apply path, and stands in for the reboot that
  would follow on a device: the instance is restarted so it reconnects,
  which is what NervesHub sees when a real device comes back.
  """

  @behaviour NervesHubLink.Client

  alias NervesHubLink.Instance

  require Logger

  @impl true
  def update_available(_update_info), do: :apply

  @impl true
  def archive_available(_archive_info), do: :ignore

  @impl true
  def archive_ready(_archive_info, _file_path), do: :ok

  @impl true
  def handle_fwup_message(_message), do: :ok

  @impl true
  def handle_error(_error), do: :ok

  @impl true
  def reconnect_backoff, do: NervesHubLink.Backoff.delay_list(1_000, 60_000, 0.5)

  @impl true
  def identify do
    Logger.info("device #{inspect(Instance.current())} asked to identify itself")
    :ok
  end

  @impl true
  def connected, do: :ok

  # Called (in a process descended from the update manager) once an update
  # has been applied. Stopping the supervisor and letting the fleet restart
  # it is the closest thing to a reboot a virtual device has.
  @impl true
  def reboot do
    case Instance.current() do
      :default ->
        :ok

      index ->
        Logger.info("device #{index} rebooting after update")
        DeviceHost.Fleet.stop_devices([index])
        :ok
    end
  end

  @impl true
  def firmware_validated?, do: true

  @impl true
  def firmware_auto_revert_detected?, do: false
end
