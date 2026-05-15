defmodule Mob.Bt do
  @moduledoc """
  Bluetooth Classic (BR/EDR) — device-level discovery, pairing, and
  cross-profile session management.

  Profile-specific operations live in submodules:

    * `Mob.Bt.Hfp` — Hands-Free Profile (audio + vendor AT commands).
      Use this for headsets, PTT-equipped earpieces, etc.
    * `Mob.Bt.Spp` — Serial Port Profile (RFCOMM byte streams).
      Use this for legacy serial-over-Bluetooth devices (Arduino HC-05,
      OBD-II readers, marine GPS, industrial sensors).
    * `Mob.Bt.Hid` — Human Interface Device (input reports).
      Use this for Bluetooth keyboards, mice, gamepads, finger PTTs.

  ## API style

  Same as the rest of Mob: callbacks return `socket` unchanged, results
  arrive in `handle_info/2` as 4-tuples:

      {:bt, event_atom, session_id_or_nil, payload}

  Discovery / pairing events use `nil` for session_id; profile events
  carry the session_id returned from the matching `connect/2`.

  ## Permissions

  Bluetooth requires runtime permissions on Android 12+ (API 31+):

    * `:bluetooth_scan` — for `start_discovery/1`
    * `:bluetooth_connect` — for `pair/2`, `connect/*`, `disconnect/2`

  Request via `Mob.Permissions.request/2` before calling Mob.Bt functions.

  ## iOS

  Bluetooth Classic on iOS requires Apple's MFi (Made for iPhone)
  certification — a paid, NDA-gated program. Mob.Bt is **Android-only**.
  All functions return `{:error, :unsupported}` synchronously on iOS.
  For iOS-equivalent custom-hardware connectivity, use `Mob.Ble`.

  ## Pairing flow

  Two pairing modes, auto-selected by whether `:pin` is given:

      # System UI flow — Android shows a system pairing dialog
      socket = Mob.Bt.pair(socket, device)

      # Programmatic — PIN supplied via API, no UI
      socket = Mob.Bt.pair(socket, device, pin: "0000")

  If the programmatic PIN fails or the device requires UI confirmation
  (e.g. numeric comparison), Android falls back to the system UI
  automatically.

  ## Disconnect

  One canonical disconnect for any profile session:

      Mob.Bt.disconnect(socket, session_id)

  The framework looks up which profile owns the session_id and routes
  to the right profile-disconnect internally. Emits a profile-specific
  event (`{:bt, :hfp_disconnected, ...}` etc).
  """

  @typedoc "An opaque session identifier for an active profile connection."
  @type session_id :: pos_integer()

  @typedoc "A discovered or paired Bluetooth device."
  @type device :: %{
          required(:address) => String.t(),
          required(:name) => String.t(),
          optional(:bond_state) => :none | :bonding | :bonded,
          optional(:device_class) => non_neg_integer(),
          optional(:uuids) => [String.t()]
        }

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  @doc """
  List currently paired (bonded) Bluetooth devices.

  Result arrives as `{:bt, :paired_devices, nil, [device]}`.
  """
  @spec list_paired(socket :: term()) :: term()
  def list_paired(socket) do
    :mob_nif.bt_list_paired()
    socket
  end

  @doc """
  Begin Bluetooth Classic discovery. Discovered devices arrive as
  individual `{:bt, :device_discovered, nil, device}` messages, terminated
  by `{:bt, :discovery_finished, nil, nil}`.

  Discovery typically runs ~12 seconds on Android.
  """
  @spec start_discovery(socket :: term()) :: term()
  def start_discovery(socket) do
    :mob_nif.bt_start_discovery()
    socket
  end

  @doc """
  Cancel an in-progress discovery.
  """
  @spec cancel_discovery(socket :: term()) :: term()
  def cancel_discovery(socket) do
    :mob_nif.bt_cancel_discovery()
    socket
  end

  @doc """
  Pair (bond) with a Bluetooth device.

  Without `:pin`, Android shows the system pairing dialog (user enters
  PIN). With `:pin`, attempts programmatic pairing using the supplied
  PIN; falls back to system UI if the device demands user confirmation.

  Result arrives as one of:

    * `{:bt, :pair_succeeded, nil, device}`
    * `{:bt, :pair_failed, nil, %{device: device, reason: atom()}}`
  """
  @spec pair(socket :: term(), device(), keyword()) :: term()
  def pair(socket, device, opts \\ []) do
    pin = Keyword.get(opts, :pin)
    json = encode_pair(device, pin)
    :mob_nif.bt_pair(json)
    socket
  end

  @doc """
  Remove an existing pairing (bond).

  Result: `{:bt, :unpaired, nil, device}`.
  """
  @spec unpair(socket :: term(), device()) :: term()
  def unpair(socket, device) do
    json = encode_device(device)
    :mob_nif.bt_unpair(json)
    socket
  end

  @doc """
  Disconnect a profile session by `session_id`.

  Works for any profile (`Mob.Bt.Hfp`, `Mob.Bt.Spp`, `Mob.Bt.Hid`) — the
  framework dispatches internally based on which profile owns the session.

  Emits a profile-specific disconnect event:

    * `{:bt, :hfp_disconnected, session_id, reason}`
    * `{:bt, :spp_disconnected, session_id, reason}`
    * `{:bt, :hid_disconnected, session_id, reason}`
  """
  @spec disconnect(socket :: term(), session_id()) :: term()
  def disconnect(socket, session_id) when is_integer(session_id) do
    :mob_nif.bt_disconnect(session_id)
    socket
  end

  # Internal JSON helpers, exposed `@doc false` so the test suite can
  # exercise the encoded shape directly (the public functions all dead-end
  # in a NIF call). Nil-safe per the VendorUsb playbook.
  # ─────────────────────────────────────────────────────────────

  @doc false
  @spec encode_pair(device(), String.t() | nil) :: binary()
  def encode_pair(device, nil), do: encode_device(device)

  def encode_pair(device, pin) when is_binary(pin) do
    device |> Map.put(:pin, pin) |> encode_device()
  end

  @doc false
  @spec encode_device(map()) :: binary()
  def encode_device(device) do
    device
    |> Map.new()
    |> drop_nil_values()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp drop_nil_values(map) do
    :maps.filter(fn _k, v -> v != nil end, map)
  end
end
