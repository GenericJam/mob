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

  ## Filtering by file type

  Pass `:types` to `pick/2` to limit what the picker offers:

      Mob.Files.pick(socket, types: ["livemd"])              # one extension
      Mob.Files.pick(socket, types: [:images, :pdf])         # semantic groups
      Mob.Files.pick(socket, types: [{:mime, "application/pdf"}])

  Each entry is one of:

    * an extension string — `"livemd"` or `".livemd"` (the leading dot is
      optional). This is the common case and matches how apps think about the
      files they own.
    * a MIME string — any value containing a slash, e.g. `"application/pdf"`
      or a wildcard `"text/*"`.
    * a semantic atom — `:images`, `:video`, `:audio`, `:pdf`, `:text`.
    * `{:extension, ext}` / `{:mime, type}` / `{:uti, id}` for an explicit
      kind. `{:uti, "dev.livebook.livemd"}` targets an iOS Uniform Type
      Identifier directly.
    * `:any` (the default) — offer everything.

  ### Platform asymmetry — read this before relying on it

  The two platforms filter differently, and a custom extension exposes the gap:

    * **iOS** filters by `UTType`, which it can derive from an extension even
      for an unregistered custom type. So `types: ["livemd"]` *strictly* limits
      the picker to `.livemd` files.
    * **Android** SAF filters by **MIME type only** — it has no extension
      filter. A custom extension with no registered MIME (`.livemd`) cannot be
      narrowed at the picker, so the picker stays wide and the user can still
      tap the "wrong" file.

  Because of this, enforce the filter on the **result** too. `pick/2` narrows
  the picker where the OS allows; `accept/2` rejects anything that slipped
  through where it doesn't, giving consistent semantics on both platforms:

      def handle_info({:files, :picked, items}, socket) do
        case Mob.Files.accept(items, ["livemd"]) do
          [%{path: path} | _] -> {:noreply, open(socket, path)}
          [] -> {:noreply, put_flash(socket, :error, "Please choose a .livemd file")}
        end
      end

  `accept/2` matches on the result's `name`/`mime`, so it enforces extensions,
  MIME types, and semantic groups. A `{:uti, _}` spec can't be checked from the
  result and is treated as already-enforced by the iOS picker.

  ## "Open with" — files handed to us by another app

  When the user opens a file *into* the app from elsewhere — e.g. a `.livemd`
  emailed to them and tapped — the OS launches (or foregrounds) the app with
  that file, provided the app declares the document type. This is a separate,
  build-time mechanism from the runtime `:types` picker filter above:

    * iOS: `CFBundleDocumentTypes` (+ an imported UTI) in `Info.plist`, and an
      `application:openURL:options:` handler that calls `mob_handle_opened_url`.
    * Android: an `<intent-filter>` for `ACTION_VIEW` / `ACTION_SEND` matching
      the mime type / extension; the Mob activity forwards it automatically.

  Retrieve it with `take_opened_document/0` from your root screen's `mount/3`.
  """

  @typedoc "A single entry in the `:types` list. See the moduledoc for the full forms."
  @type type_spec ::
          :any
          | :images
          | :video
          | :audio
          | :pdf
          | :text
          | String.t()
          | {:extension, String.t()}
          | {:mime, String.t()}
          | {:uti, String.t()}

  @doc """
  Open the system document picker.

  Pass `types: [...]` to limit what's offered (see the moduledoc). Defaults to
  `:any`. Results arrive asynchronously as `{:files, :picked, items}` /
  `{:files, :cancelled}` to the calling process.
  """
  @spec pick(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def pick(socket, opts \\ []) do
    envelope = opts |> Keyword.get(:types, :any) |> normalize_types()
    :mob_nif.files_pick(IO.iodata_to_binary(:json.encode(envelope)))
    socket
  end

  @doc """
  Normalize a `:types` value into the canonical envelope sent to the native
  picker — a list of `%{"kind" => kind, "value" => value}` maps.

  `:any` (or `"*/*"`, anywhere in the list) collapses the whole filter to `[]`,
  meaning "offer everything". Exposed so the wire contract with the iOS/Android
  native layers is testable and documented in one place.
  """
  @spec normalize_types([type_spec()] | type_spec()) :: [%{String.t() => String.t()}]
  def normalize_types(types) do
    specs = types |> List.wrap() |> Enum.map(&normalize_spec/1)
    if Enum.member?(specs, :any), do: [], else: specs
  end

  @doc """
  Keep only the items in `items` that satisfy `types` (see `matches?/2`).

  Use this in your `{:files, :picked, items}` handler to enforce a type filter
  the picker could not (notably a custom extension on Android SAF).
  """
  @spec accept([map()], [type_spec()] | type_spec()) :: [map()]
  def accept(items, types), do: Enum.filter(items, &matches?(&1, types))

  @doc """
  True if a picked/opened `item` map satisfies `types`.

  Returns `true` when `types` is empty/`:any`, or when none of the specs are
  checkable from the result (e.g. only `{:uti, _}` hints, which rely on the iOS
  picker having already filtered). Otherwise the item must match at least one
  spec by extension, MIME, or semantic group.
  """
  @spec matches?(map(), [type_spec()] | type_spec()) :: boolean()
  def matches?(item, types) do
    specs = normalize_types(types)
    enforceable = Enum.filter(specs, &enforceable?/1)

    cond do
      specs == [] -> true
      enforceable == [] -> true
      true -> Enum.any?(enforceable, &spec_matches?(&1, item))
    end
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

  # ── type-spec normalization ───────────────────────────────────────────────

  defp normalize_spec(:any), do: :any
  defp normalize_spec("*/*"), do: :any

  defp normalize_spec(group) when group in [:images, :video, :audio, :pdf, :text],
    do: %{"kind" => "semantic", "value" => Atom.to_string(group)}

  defp normalize_spec({:extension, ext}) when is_binary(ext),
    do: %{"kind" => "extension", "value" => strip_dot(ext)}

  defp normalize_spec({:mime, type}) when is_binary(type),
    do: %{"kind" => "mime", "value" => type}

  defp normalize_spec({:uti, id}) when is_binary(id),
    do: %{"kind" => "uti", "value" => id}

  defp normalize_spec(spec) when is_binary(spec) do
    if String.contains?(spec, "/"),
      do: %{"kind" => "mime", "value" => spec},
      else: %{"kind" => "extension", "value" => strip_dot(spec)}
  end

  defp strip_dot("." <> rest), do: rest
  defp strip_dot(ext), do: ext

  # ── result enforcement ────────────────────────────────────────────────────

  # UTI specs can't be checked from a result map (it carries name/mime, not a
  # UTI), so they don't enforce — the iOS picker already filtered on them.
  defp enforceable?(%{"kind" => kind}), do: kind in ["extension", "mime", "semantic"]

  defp spec_matches?(%{"kind" => "extension", "value" => ext}, item) do
    name = item[:name] || item["name"]
    is_binary(name) and String.downcase(Path.extname(name)) == "." <> String.downcase(ext)
  end

  defp spec_matches?(%{"kind" => "mime", "value" => pattern}, item) do
    mime = item[:mime] || item["mime"]
    is_binary(mime) and mime_match?(pattern, mime)
  end

  defp spec_matches?(%{"kind" => "semantic", "value" => group}, item) do
    mime = item[:mime] || item["mime"]
    is_binary(mime) and mime_match?(semantic_mime(group), mime)
  end

  defp spec_matches?(_spec, _item), do: false

  defp mime_match?("*/*", _mime), do: true

  defp mime_match?(pattern, mime) do
    case String.split(pattern, "/") do
      [type, "*"] -> String.starts_with?(String.downcase(mime), String.downcase(type) <> "/")
      _exact -> String.downcase(pattern) == String.downcase(mime)
    end
  end

  defp semantic_mime("images"), do: "image/*"
  defp semantic_mime("video"), do: "video/*"
  defp semantic_mime("audio"), do: "audio/*"
  defp semantic_mime("pdf"), do: "application/pdf"
  defp semantic_mime("text"), do: "text/*"
  defp semantic_mime(_group), do: "*/*"

  # ── open-with ─────────────────────────────────────────────────────────────

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
