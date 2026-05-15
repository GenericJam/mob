defmodule Mob.Bt.Hid do
  @moduledoc """
  Bluetooth Classic Human Interface Device (HID) — input listener.

  Use this for Bluetooth keyboards, mice, gamepads, finger PTTs, scanners,
  presenter remotes, and any device that emits HID input reports
  (button/key/axis events) over Bluetooth.

  See `Mob.Bt` for pairing, discovery, and disconnect.

  ## Scope

  This module is **read-only** by design. HID hosts (phones) almost never
  send output reports to peripherals — that's a force-feedback /
  rumble-pack edge case. If your hardware genuinely needs output reports,
  open an issue.

  ## Typical flow

      # 1. Pair (Mob.Bt.pair/2)

      # 2. Connect HID profile.
      socket = Mob.Bt.Hid.connect(socket, device)
      # {:bt, :hid_connected, session_id, device}

      # 3. Input reports stream:
      # {:bt, :hid_input, session_id,
      #   %{usage_page: 0x07, usage: 0x29, value: 1}}
      #   (HID Keyboard/Keypad, key 0x29 = Escape, pressed)

      # 4. Disconnect (Mob.Bt.disconnect/2)

  ## Input report shape

  Reports are decoded by the Android HID stack into usage-page +
  usage + value triples per the HID Usage Tables spec. Common pages:

    * `0x01` — Generic Desktop (mouse/joystick X/Y, wheel, etc.)
    * `0x07` — Keyboard/Keypad
    * `0x09` — Button (gamepad face buttons)
    * `0x0C` — Consumer (volume, play, mute, custom)
    * `0xFF00`–`0xFFFF` — Vendor-defined

  Multi-axis events arrive as separate messages, one per axis. Synthesize
  combined input on the receive side if needed.

  ## Receiving raw reports

  If the device's HID descriptor is non-standard or the high-level
  `:hid_input` shape isn't sufficient, subscribe to raw reports with
  `subscribe_raw/2` and parse the bytes yourself.

  Stream: `{:bt, :hid_raw_report, session_id, %{report_id: integer, bytes: binary}}`.
  """

  alias Mob.Bt

  @doc """
  Open an HID profile connection to `device`. The device must already be
  paired.

  Result: `{:bt, :hid_connected, session_id, device}` on success,
  `{:bt, :hid_connect_failed, nil, %{device: device, reason: atom()}}`
  on failure.
  """
  @spec connect(socket :: term(), Bt.device()) :: term()
  def connect(socket, device) do
    json = Bt.encode_device(device)
    :mob_nif.bt_hid_connect(json)
    socket
  end

  @doc """
  Subscribe to raw HID input reports (bypasses Android's parser).

  Use only when the device's HID descriptor is non-standard or the
  high-level `:hid_input` events miss data you need.

  Stream: `{:bt, :hid_raw_report, session_id, %{report_id, bytes}}`.
  """
  @spec subscribe_raw(socket :: term(), Bt.session_id()) :: term()
  def subscribe_raw(socket, session_id) when is_integer(session_id) do
    :mob_nif.bt_hid_subscribe_raw(session_id)
    socket
  end
end
