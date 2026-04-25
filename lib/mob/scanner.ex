defmodule Mob.Scanner do
  @moduledoc """
  QR code and barcode scanner.

  Requires `:camera` permission (request via `Mob.Permissions.request/2`).

  Opens a full-screen camera preview. When a code is detected the view dismisses
  automatically and the result is delivered to `handle_info`:

      handle_info({:scan, :result,    %{type: :qr, value: "https://..."}}, socket)
      handle_info({:scan, :cancelled},                                       socket)

  iOS: `AVCaptureMetadataOutput`. Android: `CameraX` + ML Kit `BarcodeScanning`.

  > **Android dependency:** add to `app/build.gradle`:
  > `implementation 'com.google.mlkit:barcode-scanning:17.2.0'`
  > `implementation 'androidx.camera:camera-camera2:1.3.0'`
  > `implementation 'androidx.camera:camera-lifecycle:1.3.0'`
  > `implementation 'androidx.camera:camera-view:1.3.0'`
  """

  @type format ::
          :qr
          | :ean13
          | :ean8
          | :code128
          | :code39
          | :upca
          | :upce
          | :pdf417
          | :aztec
          | :data_matrix

  @doc """
  Open the barcode scanner.

  Options:
    - `formats: [format]` — list of barcode formats to detect (default `[:qr]`)
  """
  @spec scan(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def scan(socket, opts \\ []) do
    formats = Keyword.get(opts, :formats, [:qr]) |> Enum.map(&Atom.to_string/1)
    formats_json = :json.encode(formats)
    :mob_nif.scanner_scan(formats_json)
    socket
  end
end
