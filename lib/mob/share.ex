defmodule Mob.Share do
  @moduledoc """
  System share sheet. Opens the OS share dialog with text or a local file.
  Fire-and-forget — `text/2` and `file/3` always return the socket unchanged.

  ## Usage

      def handle_event("share", _params, socket) do
        {:noreply, Mob.Share.text(socket, "Check out Mob: https://github.com/genericjam/mob")}
      end

      def handle_info({:tap, :export}, socket) do
        path = Path.join(Mob.Storage.dir(:cache), "exports/report.pdf")
        {:noreply, Mob.Share.file(socket, path, title: "Quarterly Report")}
      end

      def handle_info({:mob_share, :error, reason}, socket) do
        {:noreply, Mob.Alert.toast(socket, "Share failed: \#{reason}")}
      end

  ## Message contract

  `file/3` delivers setup failures asynchronously (or immediately from Elixir
  when the file is missing) to the calling process (`self()`) as
  `{:mob_share, :error, reason}` where `reason` is one of:

  - `:not_found` — the path does not exist, is a directory, or is unreadable
  - `:no_activity` — no foreground activity (Android) or active window scene presenter (iOS)
  - `:no_app` — no target app can handle the share intent (Android)
  - `:failed` — FileProvider URI or native share setup threw an error
  - `:unsupported` — the Android host `MobBridge` predates `shareFile`

  Success, completion, and user cancellation of the share sheet are never reported.

  ## Platform notes

  - **Android** shares via `Intent.ACTION_SEND` wrapped in `Intent.createChooser`,
    backed by `androidx.core.content.FileProvider`. The file MUST live under a root
    declared in the host's `res/xml/file_provider_paths.xml`. Generated `mob_new`
    apps cover the whole app cache directory (`Mob.Storage.dir(:cache)`), so write
    shared exports under the cache directory; sharing a path outside any configured
    root delivers `{:mob_share, :error, :failed}`. Older `mob_new` hosts without
    `MobBridge.shareFile` deliver `{:mob_share, :error, :unsupported}`.
  - **iOS** shares a `file://` `NSURL` through `UIActivityViewController` (with a
    `UIActivityItemSource` item supplying the file URL, subject title, and UTI
    type identifier derived from `:mime`), presented with a centered popover
    anchor on iPad.
  """

  @type error_reason :: :not_found | :no_activity | :no_app | :failed | :unsupported

  @mime_types %{
    ".pdf" => "application/pdf",
    ".txt" => "text/plain",
    ".csv" => "text/csv",
    ".json" => "application/json",
    ".html" => "text/html",
    ".htm" => "text/html",
    ".xml" => "application/xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".heic" => "image/heic",
    ".mp3" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".aac" => "audio/aac",
    ".flac" => "audio/flac",
    ".mid" => "audio/midi",
    ".midi" => "audio/midi",
    ".mp4" => "video/mp4",
    ".mov" => "video/quicktime",
    ".zip" => "application/zip",
    ".musicxml" => "application/vnd.recordare.musicxml+xml",
    ".mxl" => "application/vnd.recordare.musicxml"
  }

  @doc """
  Open the share sheet with plain text. Returns the socket unchanged.
  """
  @spec text(Mob.Socket.t(), binary()) :: Mob.Socket.t()
  def text(socket, content) when is_binary(content) do
    :mob_nif.share_text(content)
    socket
  end

  @doc """
  Open the share sheet with a local file. Always returns the socket unchanged.

  `path` may be a binary or chardata and is resolved with `Path.absname/1`.
  Setup errors are sent to `self()` as `{:mob_share, :error, reason}`.

  ## Options

  - `:mime` — non-empty MIME type string containing `"/"`. Defaults to a type
    derived case-insensitively from the file extension, falling back to
    `"application/octet-stream"`.
  - `:title` — non-empty share title string. Defaults to `Path.basename(path)`.
  """
  @spec file(Mob.Socket.t(), Path.t(), keyword()) :: Mob.Socket.t()
  def file(socket, path, opts \\ []) do
    __file__(socket, path, opts, :mob_nif)
  end

  @doc false
  @spec __file__(Mob.Socket.t(), Path.t(), keyword(), module()) :: Mob.Socket.t()
  def __file__(socket, path, opts, nif) do
    validated = Keyword.validate!(opts, [:mime, :title])
    abs_path = path |> IO.chardata_to_string() |> Path.absname()
    mime = resolve_mime!(abs_path, validated)
    title = resolve_title!(abs_path, validated)

    if File.regular?(abs_path) do
      dispatch_file(abs_path, mime, title, nif)
    else
      send(self(), {:mob_share, :error, :not_found})
    end

    socket
  end

  defp dispatch_file(abs_path, mime, title, nif) do
    case nif.share_file(abs_path, mime, title) do
      :ok -> :ok
      {:error, reason} -> send(self(), {:mob_share, :error, reason})
    end
  end

  defp resolve_mime!(abs_path, opts) do
    case Keyword.fetch(opts, :mime) do
      :error ->
        ext = abs_path |> Path.extname() |> String.downcase()
        Map.get(@mime_types, ext, "application/octet-stream")

      {:ok, mime} ->
        if valid_mime?(mime) do
          mime
        else
          raise ArgumentError,
                "expected :mime to be a non-empty binary containing \"/\", got: #{inspect(mime)}"
        end
    end
  end

  defp valid_mime?(mime) when is_binary(mime), do: mime != "" and String.contains?(mime, "/")
  defp valid_mime?(_), do: false

  defp resolve_title!(abs_path, opts) do
    case Keyword.fetch(opts, :title) do
      :error ->
        Path.basename(abs_path)

      {:ok, title} when is_binary(title) and title != "" ->
        title

      {:ok, title} ->
        raise ArgumentError,
              "expected :title to be a non-empty binary, got: #{inspect(title)}"
    end
  end
end
