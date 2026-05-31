defmodule Mob.Files do
  @moduledoc """
  System file picker. Opens the OS document picker (Files app on iOS, SAF on Android).

  No permission required — the user explicitly selects files.

  Results arrive as:

      handle_info({:files, :picked,    items},   socket)
      handle_info({:files, :cancelled},           socket)

  Each item in `items` is:

      %{path: "/tmp/mob_file_xxx.pdf", name: "report.pdf",
        mime: "application/pdf", size: 102400}

  iOS: `UIDocumentPickerViewController`. Android: `OpenMultipleDocuments`.

  ## "Open with" — files handed to us by another app

  When the user opens a file *into* the app from elsewhere — e.g. a `.livemd`
  emailed to them and tapped — the OS launches (or foregrounds) the app with
  that file, provided the app declares the document type:

    * iOS: `CFBundleDocumentTypes` (+ an imported UTI) in `Info.plist`, and an
      `application:openURL:options:` handler that calls `mob_handle_opened_url`.
    * Android: an `<intent-filter>` for `ACTION_VIEW` / `ACTION_SEND` matching
      the mime type / extension; the Mob activity forwards it automatically.

  Retrieve it with `take_opened_document/0` from your root screen's `mount/3`.
  """

  @spec pick(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def pick(socket, opts \\ []) do
    types = Keyword.get(opts, :types, ["*/*"])
    types_json = :json.encode(types)
    :mob_nif.files_pick(types_json)
    socket
  end

  @doc """
  Return the document another app asked us to open, or `:none`.

  Call once from your root screen's `mount/3`. The item has the same shape as
  `pick/2` results:

      %{path: "/tmp/demo.livemd", name: "demo.livemd",
        mime: "text/markdown", size: 1234}

  The copied file lives in the app's tmp dir, so read or move it promptly. This
  call also registers the calling process to receive any file opened *later*
  while the app is already running, delivered as:

      handle_info({:files, :opened, item}, socket)

  Returns `:none` off-device or when nothing is pending. See the moduledoc for
  the platform manifest/Info.plist wiring "open with" requires.
  """
  @spec take_opened_document() :: map() | :none
  def take_opened_document do
    case safe_take_opened() do
      json when is_binary(json) -> decode_opened_item(json)
      _ -> :none
    end
  end

  defp safe_take_opened do
    :mob_nif.take_opened_document()
  rescue
    UndefinedFunctionError -> :none
    ErlangError -> :none
  end

  defp decode_opened_item(json) do
    case :json.decode(json) do
      %{"path" => path} = m ->
        %{path: path, name: m["name"], mime: m["mime"], size: m["size"]}

      _ ->
        :none
    end
  end
end
