defmodule Mob.Bt.Hfp do
  @moduledoc """
  Bluetooth Classic Hands-Free Profile (HFP) — audio + vendor AT commands.

  Use this for headsets, PTT-equipped earpieces (Hytera EHW02, etc), and
  any device that exposes an HFP control link plus an SCO audio link.

  See `Mob.Bt` for pairing, discovery, and disconnect — those are
  device-level concerns. Profile-specific operations live here.

  ## Typical flow

      # 1. Pair (only needed once per device — Mob.Bt.pair/2)
      socket = Mob.Bt.pair(socket, device)
      # {:bt, :pair_succeeded, nil, device}

      # 2. Connect HFP profile
      socket = Mob.Bt.Hfp.connect(socket, device)
      # {:bt, :hfp_connected, session_id, device}

      # 3. (Optional) subscribe to vendor AT commands the headset emits.
      #    Hytera EHW02 fires +CTXD on PTT press, +CUTXC on release.
      socket = Mob.Bt.Hfp.subscribe_vendor_at(socket, session_id)
      # {:bt, :vendor_at, session_id, %{cmd: "+CTXD", args: ""}}

      # 4. (Optional) bring up the SCO audio link.
      socket = Mob.Bt.Hfp.start_sco(socket, session_id)
      # {:bt, :sco_started, session_id, %{sample_rate: 8000, ...}}
      # then audio chunks stream as:
      # {:bt, :sco_audio_in, session_id, pcm_bytes}

      # 5. Send PCM audio out to the headset earpiece:
      Mob.Bt.Hfp.send_audio(socket, session_id, pcm_bytes)

      # 6. Disconnect (one canonical path — Mob.Bt.disconnect/2)
      Mob.Bt.disconnect(socket, session_id)

  ## Vendor AT commands

  HFP defines a small core AT vocabulary (call control, volume, ring).
  Headset vendors extend with their own `+`-prefixed commands. Subscribing
  via `subscribe_vendor_at/2` delivers any *unrecognized* AT command from
  the headset as `{:bt, :vendor_at, session_id, %{cmd, args}}` for your
  app to interpret.

  Sending a vendor AT command to the headset is `send_vendor_at/4`.
  Standard responses (`OK`, `ERROR`) are emitted by Android automatically —
  use the `response` argument to override only when the AT spec demands
  custom payload.

  ## SCO audio

  SCO (Synchronous Connection-Oriented) is the real-time bidirectional
  voice channel HFP uses for call audio. `start_sco/2` opens it; PCM
  bytes flow both ways until `stop_sco/2` or disconnect.

  Format is 8 kHz / 16-bit / mono PCM by default; modern devices may
  negotiate up to 16 kHz wideband (mSBC). The `:sco_started` event
  reports the negotiated parameters.
  """

  alias Mob.Bt

  @doc """
  Open an HFP profile connection to `device`. The device must already
  be paired (`Mob.Bt.pair/2`).

  Result: `{:bt, :hfp_connected, session_id, device}` on success,
  `{:bt, :hfp_connect_failed, nil, %{device: device, reason: atom()}}`
  on failure.
  """
  @spec connect(socket :: term(), Bt.device()) :: term()
  def connect(socket, device) do
    json = encode_device(device)
    :mob_nif.bt_hfp_connect(json)
    socket
  end

  @doc """
  Subscribe to vendor-specific AT commands emitted by the headset on the
  given HFP session.

  The caller specifies which BT SIG company IDs to listen for via the
  `:company_ids` option. Android's ACTION_VENDOR_SPECIFIC_HEADSET_EVENT
  broadcasts are only delivered for explicitly-registered IDs, so a
  default empty list means no events will be received.

  Common values:

    * `313`  — Hytera (PTT commercial radios)
    * `76`   — Apple (AirPods custom events)
    * `10`   — Qualcomm
    * `1117` — Plantronics / Poly

  Standard (non-vendor) AT commands are handled by Android's HFP stack
  and never surface here.

  Stream events: `{:bt, :vendor_at, session_id, %{cmd: String.t(), cmd_type: integer(), args: String.t(), address: String.t()}}`.

  ## Example

      Mob.Bt.Hfp.subscribe_vendor_at(socket, session_id, company_ids: [313])
  """
  @spec subscribe_vendor_at(socket :: term(), Bt.session_id(), keyword()) :: term()
  def subscribe_vendor_at(socket, session_id, opts \\ [])
      when is_integer(session_id) and is_list(opts) do
    company_ids = Keyword.get(opts, :company_ids, [])
    json = Jason.encode!(%{company_ids: company_ids})
    :mob_nif.bt_hfp_subscribe_vendor_at(session_id, json)
    socket
  end

  @doc """
  Send a vendor AT command to the headset. Useful for headset-specific
  feature toggles or query/response protocols.

      Mob.Bt.Hfp.send_vendor_at(socket, session, "+XAPL", "0505,2")
  """
  @spec send_vendor_at(socket :: term(), Bt.session_id(), String.t(), String.t()) :: term()
  def send_vendor_at(socket, session_id, cmd, args \\ "")
      when is_integer(session_id) and is_binary(cmd) and is_binary(args) do
    :mob_nif.bt_hfp_send_vendor_at(session_id, cmd, args)
    socket
  end

  @doc """
  Open the SCO audio link for this HFP session.

  Emits `{:bt, :sco_started, session_id, %{sample_rate: integer, encoding: atom, channels: integer}}`
  when the link is up. Mic audio then streams as
  `{:bt, :sco_audio_in, session_id, pcm_bytes}`.

  On failure: `{:bt, :sco_failed, session_id, reason}`.
  """
  @spec start_sco(socket :: term(), Bt.session_id()) :: term()
  def start_sco(socket, session_id) when is_integer(session_id) do
    :mob_nif.bt_hfp_start_sco(session_id)
    socket
  end

  @doc """
  Close the SCO audio link without disconnecting the HFP session.

  Emits `{:bt, :sco_stopped, session_id, nil}`.
  """
  @spec stop_sco(socket :: term(), Bt.session_id()) :: term()
  def stop_sco(socket, session_id) when is_integer(session_id) do
    :mob_nif.bt_hfp_stop_sco(session_id)
    socket
  end

  @doc """
  Send PCM audio bytes out the SCO link to the headset earpiece.

  Bytes are linear PCM matching the format reported in `:sco_started`
  (typically 8 kHz / 16-bit / mono signed little-endian).

  Returns the socket. This is fire-and-forget; no completion event.
  """
  @spec send_audio(socket :: term(), Bt.session_id(), binary()) :: term()
  def send_audio(socket, session_id, pcm_bytes)
      when is_integer(session_id) and is_binary(pcm_bytes) do
    :mob_nif.bt_hfp_send_audio(session_id, pcm_bytes)
    socket
  end

  @doc false
  # ─────────────────────────────────────────────────────────────
  # JSON helpers
  # ─────────────────────────────────────────────────────────────

  defp encode_device(device) do
    device
    |> Map.new()
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end
