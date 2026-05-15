defmodule Mob.Bt.Spp do
  @moduledoc """
  Bluetooth Classic Serial Port Profile (SPP) — RFCOMM byte streams.

  Use this for legacy serial-over-Bluetooth devices: Arduino HC-05/HC-06
  modules, OBD-II ELM327 readers, marine GPS pucks, industrial sensors,
  legacy barcode scanners, etc. Anything that exposes itself as a
  bidirectional byte pipe over a custom RFCOMM channel UUID.

  See `Mob.Bt` for pairing, discovery, and disconnect.

  ## Typical flow

      # 1. Pair (Mob.Bt.pair/2)

      # 2. Connect SPP, supplying the RFCOMM service UUID.
      #    The well-known SPP UUID is "00001101-0000-1000-8000-00805F9B34FB".
      socket = Mob.Bt.Spp.connect(socket, device,
                 uuid: "00001101-0000-1000-8000-00805F9B34FB")
      # {:bt, :spp_connected, session_id, device}

      # 3. Receive bytes:
      # {:bt, :spp_data, session_id, bytes}

      # 4. Send bytes:
      Mob.Bt.Spp.write(socket, session_id, "ATZ\\r\\n")

      # 5. Disconnect (Mob.Bt.disconnect/2)

  ## UUIDs

  Most SPP devices advertise the standard SPP UUID
  `00001101-0000-1000-8000-00805F9B34FB`. Some manufacturers use custom
  UUIDs to scope to a specific protocol on the same physical device.
  Pass via the `:uuid` opt; if omitted, the standard SPP UUID is used.

  ## Insecure RFCOMM

  By default the connection uses the secure RFCOMM channel (encrypted,
  requires bond). Some legacy devices (especially HC-06 clones) only
  accept insecure RFCOMM. Pass `secure: false` to fall back.
  """

  alias Mob.Bt

  @standard_spp_uuid "00001101-0000-1000-8000-00805F9B34FB"

  @doc """
  Open an SPP (RFCOMM) connection to `device`.

  ## Options

    * `:uuid` — RFCOMM service UUID (default: `"#{@standard_spp_uuid}"`)
    * `:secure` — `true` (default, encrypted) or `false` (legacy insecure)

  Result: `{:bt, :spp_connected, session_id, device}` on success,
  `{:bt, :spp_connect_failed, nil, %{device: device, reason: atom()}}`
  on failure.
  """
  @spec connect(socket :: term(), Bt.device(), keyword()) :: term()
  def connect(socket, device, opts \\ []) do
    json = encode_connect(device, opts)
    :mob_nif.bt_spp_connect(json)
    socket
  end

  @doc false
  @spec encode_connect(Bt.device(), keyword()) :: binary()
  def encode_connect(device, opts) when is_list(opts) do
    uuid = Keyword.get(opts, :uuid, @standard_spp_uuid)
    secure = Keyword.get(opts, :secure, true)

    device
    |> Map.put(:uuid, uuid)
    |> Map.put(:secure, secure)
    |> Bt.encode_device()
  end

  @doc """
  Write a byte payload to the SPP session.

  Returns the socket. Fire-and-forget: bytes are queued in Kotlin's
  output stream and flushed asynchronously. No completion event.

  Errors during write are surfaced as
  `{:bt, :spp_disconnected, session_id, reason}` (Kotlin closes the
  socket on write failure).
  """
  @spec write(socket :: term(), Bt.session_id(), binary()) :: term()
  def write(socket, session_id, bytes)
      when is_integer(session_id) and is_binary(bytes) do
    :mob_nif.bt_spp_write(session_id, bytes)
    socket
  end
end
