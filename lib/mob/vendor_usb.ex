defmodule Mob.VendorUsb do
  @moduledoc """
  Raw USB host access via vendor bulk endpoints. **Android only.**

  No permission required at the OS-permission level, but Android prompts the
  user to grant per-device access via the system dialog when you call
  `request_permission/2`. The grant is per app + device + session; granting
  "always" only sticks if the user ticks the checkbox.

  iOS calls return the socket unchanged and emit
  `{:peripheral, :vendor_usb, :error, nil, :unsupported}`. See
  `Mob.Ble` for iOS-friendly equivalent transports.
  the (forthcoming) `Mob.Midi` or `Mob.Ble`.

  ## Lifecycle

  ```
  list_devices/1          → {:peripheral, :vendor_usb, :devices, _, [device, …]}
  request_permission/2    → {:peripheral, :vendor_usb, :permission_granted, _, device}
                            {:peripheral, :vendor_usb, :permission_denied, _, device}
  open/2                  → {:peripheral, :vendor_usb, :opened, session, device}
                            {:peripheral, :vendor_usb, :error, nil, reason}
  bulk_write/4            → {:peripheral, :vendor_usb, :write_complete, session, %{bytes: n}}
                            (or :error for failures)
  start_reading/3         → {:peripheral, :vendor_usb, :data, session, binary}
                            (delivered repeatedly; use stop_reading/2 to halt)
  stop_reading/2
  close/2                 → {:peripheral, :vendor_usb, :closed, session, reason}
  ```

  Any unsolicited `{:peripheral, :vendor_usb, :disconnected, session, reason}`
  may arrive at any time (cable unplug, device removed). After
  `:disconnected`, the session handle is dead — drop your reference and call
  `list_devices/1` again to reacquire.

  ## Example: a USB echo demo

  This shape works for any USB device that exposes bulk IN/OUT
  endpoints. Substitute the VID/PID and frame format for your device.

      defmodule MyApp.UsbScreen do
        use Mob.Screen
        alias Mob.VendorUsb

        @my_vid 0x1234
        @my_pid 0x5678

        def mount(_p, _s, socket) do
          {:ok,
           socket
           |> Mob.Socket.assign(:devices, [])
           |> Mob.Socket.assign(:session, nil)
           |> VendorUsb.list_devices(vendor_id: @my_vid)}
        end

        def handle_info({:peripheral, :vendor_usb, :devices, _, devices}, socket) do
          {:noreply, Mob.Socket.assign(socket, :devices, devices)}
        end

        def handle_info({:peripheral, :vendor_usb, :permission_granted, _, dev}, socket) do
          {:noreply, VendorUsb.open(socket, dev, interface: 0)}
        end

        def handle_info({:peripheral, :vendor_usb, :opened, session, _dev}, socket) do
          socket =
            socket
            |> Mob.Socket.assign(:session, session)
            |> VendorUsb.start_reading(session)
            |> VendorUsb.bulk_write(session, "hello")

          {:noreply, socket}
        end

        def handle_info({:peripheral, :vendor_usb, :data, _session, binary}, socket) do
          IO.inspect(binary, label: "from device")
          {:noreply, socket}
        end

        def handle_info({:peripheral, :vendor_usb, :disconnected, _, _}, socket) do
          {:noreply, Mob.Socket.assign(socket, :session, nil)}
        end
      end

  ## Framing is your problem

  This module is byte-level. USB bulk endpoints do *not* preserve message
  boundaries — the bytes you wrote in one `bulk_write/4` call may arrive
  on the other end split across multiple chunks, or coalesced with later
  writes. Likewise, `:data` events deliver whatever the OS happens to
  hand back from a read; do not assume one event corresponds to one
  logical message.

  If your device uses a framed protocol (length-prefix, COBS, SLIP,
  delimiters, fixed-size records), implement the framer in a layer
  above this one. A reasonable pattern is a `GenServer` that owns the
  session, accumulates incoming chunks into a buffer, and drains
  complete frames out for higher-level consumers.

  ## Device shape

  Devices arrive as maps:

      %{
        vendor_id:    0x1234,
        product_id:   0x5678,
        manufacturer: "Acme Inc.",
        product:      "Widget 9000",
        serial:       "SN-000001",
        # opaque handle the OS uses to refer to this device. Treat as a
        # binary; do not parse. Pass back to `request_permission/2` etc.
        ref:          "/dev/bus/usb/001/002"
      }

  ## Session handles

  `open/2` delivers an integer session handle. Session handles are valid
  until `:disconnected` or `close/2`. They are *not* persistent across app
  restarts — re-enumerate after launch.

  ## Buffer ownership

  Binaries you pass to `bulk_write/4` are copied into a native-side buffer
  before the NIF returns. Binaries delivered via `:data` are owned by the
  BEAM — they will outlive the underlying USB read buffer.

  ## Limits

  Maximum write size per call: 16 KiB. Larger writes are rejected with
  `{:error, :payload_too_large}`. Read chunks are bounded by the USB max
  packet size for the endpoint (typically 64 B Full Speed, 512 B High
  Speed); the native read loop coalesces packets into BEAM-side binaries
  bounded by `:read_chunk_bytes` (default 4 KiB).
  """

  @type device :: %{
          vendor_id: non_neg_integer(),
          product_id: non_neg_integer(),
          manufacturer: String.t() | nil,
          product: String.t() | nil,
          serial: String.t() | nil,
          ref: String.t()
        }

  @type session :: integer()

  @max_write_bytes 16 * 1024

  @doc """
  Enumerate connected USB devices.

  Result: `{:peripheral, :vendor_usb, :devices, nil, [device, …]}`

  Options:
    * `:vendor_id` — filter to a single VID
    * `:product_id` — filter to a single PID (only meaningful with VID)

  Filtering happens native-side; an empty result is a real "no matching
  device", not a permission/availability issue.
  """
  @spec list_devices(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def list_devices(socket, opts \\ []) do
    filter =
      %{}
      |> maybe_put_filter("vendor_id", Keyword.get(opts, :vendor_id))
      |> maybe_put_filter("product_id", Keyword.get(opts, :product_id))

    json = :json.encode(filter)
    :mob_nif.vendor_usb_list_devices(json)
    socket
  end

  defp maybe_put_filter(map, _key, nil), do: map
  defp maybe_put_filter(map, key, val), do: Map.put(map, key, val)

  @doc """
  Ask the OS to prompt the user to grant access to a specific device.

  `device` is the map returned by `list_devices/1`. Only the `:ref` field
  is consulted, but it is convenient to pass the whole map.

  Result:
    * `{:peripheral, :vendor_usb, :permission_granted, nil, device}`
    * `{:peripheral, :vendor_usb, :permission_denied,  nil, device}`

  Idempotent. If the user has already granted access, the granted message
  fires immediately without showing a dialog.
  """
  @spec request_permission(Mob.Socket.t(), device()) :: Mob.Socket.t()
  def request_permission(socket, %{ref: ref} = _device) when is_binary(ref) do
    :mob_nif.vendor_usb_request_permission(ref)
    socket
  end

  @doc """
  Open a permitted device and claim an interface.

  Options:
    * `:interface` — interface number (default `0`)
    * `:endpoint_in` — bulk IN endpoint address (e.g. `0x81`); if omitted,
      the first bulk IN endpoint on the interface is auto-selected
    * `:endpoint_out` — bulk OUT endpoint address (e.g. `0x01`); if
      omitted, the first bulk OUT endpoint on the interface is
      auto-selected

  Result:
    * `{:peripheral, :vendor_usb, :opened, session, device}`
    * `{:peripheral, :vendor_usb, :error, nil, reason}` — common reasons:
      `:no_permission`, `:device_gone`, `:interface_busy`,
      `:no_bulk_endpoints`
  """
  @spec open(Mob.Socket.t(), device(), keyword()) :: Mob.Socket.t()
  def open(socket, %{ref: ref}, opts \\ []) when is_binary(ref) do
    fields =
      %{"ref" => ref, "interface" => Keyword.get(opts, :interface, 0)}
      |> maybe_put_filter("endpoint_in", Keyword.get(opts, :endpoint_in))
      |> maybe_put_filter("endpoint_out", Keyword.get(opts, :endpoint_out))

    json = :json.encode(fields)
    :mob_nif.vendor_usb_open(json)
    socket
  end

  @doc """
  Send bytes to the device's bulk OUT endpoint.

  `data` may be a binary or iolist; it is flattened and copied native-side
  before the NIF returns. Maximum size: #{@max_write_bytes} bytes.

  Options:
    * `:timeout_ms` — write timeout (default `1000`)

  Result:
    * `{:peripheral, :vendor_usb, :write_complete, session, %{bytes: n}}`
    * `{:peripheral, :vendor_usb, :error, session, reason}`
  """
  @spec bulk_write(Mob.Socket.t(), session(), iodata(), keyword()) :: Mob.Socket.t()
  def bulk_write(socket, session, data, opts \\ []) when is_integer(session) do
    bin = IO.iodata_to_binary(data)

    cond do
      byte_size(bin) == 0 ->
        socket

      byte_size(bin) > @max_write_bytes ->
        send(self(), {:peripheral, :vendor_usb, :error, session, :payload_too_large})
        socket

      true ->
        timeout = Keyword.get(opts, :timeout_ms, 1000)
        :mob_nif.vendor_usb_bulk_write(session, bin, timeout)
        socket
    end
  end

  @doc """
  Start a continuous read loop on the bulk IN endpoint.

  After this call, every chunk read native-side is delivered as
  `{:peripheral, :vendor_usb, :data, session, binary}` to the calling
  process. Stop with `stop_reading/2`.

  Options:
    * `:read_chunk_bytes` — soft cap on per-message coalescing (default
      `4096`). Smaller values reduce latency; larger reduce overhead.

  Idempotent: calling twice is a no-op.
  """
  @spec start_reading(Mob.Socket.t(), session(), keyword()) :: Mob.Socket.t()
  def start_reading(socket, session, opts \\ []) when is_integer(session) do
    chunk = Keyword.get(opts, :read_chunk_bytes, 4096)
    :mob_nif.vendor_usb_start_reading(session, chunk)
    socket
  end

  @doc "Stop the read loop started by `start_reading/3`."
  @spec stop_reading(Mob.Socket.t(), session()) :: Mob.Socket.t()
  def stop_reading(socket, session) when is_integer(session) do
    :mob_nif.vendor_usb_stop_reading(session)
    socket
  end

  @doc """
  Close a device session, releasing the interface and freeing the file
  descriptor. Idempotent. Always emits
  `{:peripheral, :vendor_usb, :closed, session, :ok}`.
  """
  @spec close(Mob.Socket.t(), session()) :: Mob.Socket.t()
  def close(socket, session) when is_integer(session) do
    :mob_nif.vendor_usb_close(session)
    socket
  end

  # ── Event normalization ────────────────────────────────────────────────
  #
  # The Android NIF delivers a few high-cardinality events with their
  # payloads as JSON binaries (`:devices_json`, `:permission_granted_json`,
  # `:permission_denied_json`, `:opened_json`) to keep the C/JNI side
  # simple. `Mob.Screen` calls `normalize_message/1` once before the
  # screen's `handle_info/2` runs, so user code only sees the public event
  # shape documented at the top of this module.

  @doc false
  @spec normalize_message(term()) :: term()
  def normalize_message({:peripheral, :vendor_usb, :devices_json, _, json})
      when is_binary(json) do
    devices = json |> :json.decode() |> Enum.map(&device_from_map/1)
    {:peripheral, :vendor_usb, :devices, nil, devices}
  end

  def normalize_message({:peripheral, :vendor_usb, :permission_granted_json, _, json}) do
    {:peripheral, :vendor_usb, :permission_granted, nil, device_from_map(:json.decode(json))}
  end

  def normalize_message({:peripheral, :vendor_usb, :permission_denied_json, _, json}) do
    {:peripheral, :vendor_usb, :permission_denied, nil, device_from_map(:json.decode(json))}
  end

  def normalize_message({:peripheral, :vendor_usb, :opened_json, session, json}) do
    {:peripheral, :vendor_usb, :opened, session, device_from_map(:json.decode(json))}
  end

  def normalize_message(other), do: other

  defp device_from_map(map) when is_map(map) do
    %{
      vendor_id: Map.get(map, "vendor_id"),
      product_id: Map.get(map, "product_id"),
      manufacturer: Map.get(map, "manufacturer"),
      product: Map.get(map, "product"),
      serial: Map.get(map, "serial"),
      ref: Map.get(map, "ref")
    }
  end
end
