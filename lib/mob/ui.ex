defmodule Mob.UI do
  @moduledoc """
  UI component constructors for the Mob framework.

  Each function returns a node map compatible with `Mob.Renderer`. These can
  be used directly, via the `~MOB` sigil, or mixed freely — they produce the
  same map format.

      # Native map literal
      %{type: :text, props: %{text: "Hello"}, children: []}

      # Component function (keyword list or map)
      Mob.UI.text(text: "Hello")

      # Sigil (import Mob.Sigil or use Mob.Screen)
      ~MOB(<Text text="Hello" />)

  All three forms produce identical output and are accepted by `Mob.Renderer`.
  """

  @text_props [:text, :text_color, :text_size]

  @doc """
  Returns a `:text` leaf node.

  ## Props

    * `:text` — the string to display (required)
    * `:text_color` — color value passed to `set_text_color/2` in the NIF
    * `:text_size` — font size in sp passed to `set_text_size/2` in the NIF

  ## Examples

      Mob.UI.text(text: "Hello")
      #=> %{type: :text, props: %{text: "Hello"}, children: []}

      Mob.UI.text(text: "Hello", text_color: "#ffffff", text_size: 18)
      #=> %{type: :text, props: %{text: "Hello", text_color: "#ffffff", text_size: 18}, children: []}
  """
  @spec text(keyword() | map()) :: map()
  def text(props) when is_list(props), do: text(Map.new(props))

  def text(%{} = props) do
    %{
      type: :text,
      props: Map.take(props, @text_props),
      children: []
    }
  end

  @doc """
  Returns a `:webview` component node. Renders a native web view inline.

  The JS bridge is injected automatically — the page can call `window.mob.send(data)`
  to deliver messages to `handle_info({:webview, :message, data}, socket)`, and
  Elixir can push to JS via `Mob.WebView.post_message/2`.

  Props:
    * `:url` — URL to load (required)
    * `:allow` — list of URL prefixes that navigation is permitted to (default: allow all).
      Blocked attempts arrive as `{:webview, :blocked, url}` in `handle_info`.
    * `:show_url` — show a native URL label above the WebView (default: false)
    * `:title` — static title label above the WebView; overrides `:show_url`
    * `:width`, `:height` — dimensions in dp/pts; omit to fill parent
  """
  @spec webview(keyword() | map()) :: map()
  def webview(props \\ [])
  def webview(props) when is_list(props), do: webview(Map.new(props))

  def webview(%{} = props) do
    allow_str = (props[:allow] || []) |> Enum.join(",")

    node_props =
      %{url: props[:url] || "", allow: allow_str, show_url: props[:show_url] || false}
      |> then(fn p -> if props[:title], do: Map.put(p, :title, props[:title]), else: p end)
      |> then(fn p -> if props[:width], do: Map.put(p, :width, props[:width]), else: p end)
      |> then(fn p -> if props[:height], do: Map.put(p, :height, props[:height]), else: p end)

    %{type: :web_view, props: node_props, children: []}
  end

  @doc """
  Returns a `:camera_preview` component node. Renders a live camera feed inline.

  Call `MobCamera.start_preview/2` (the `mob_camera` plugin) before mounting this
  component, and `MobCamera.stop_preview/1` when done.

  Props:
    * `:facing` — `:back` (default) or `:front`
    * `:width`, `:height` — dimensions in dp/pts; omit to fill parent
  """
  @spec camera_preview(keyword() | map()) :: map()
  def camera_preview(props \\ [])
  def camera_preview(props) when is_list(props), do: camera_preview(Map.new(props))

  def camera_preview(%{} = props) do
    %{
      type: :camera_preview,
      props: Map.take(props, [:facing, :width, :height]),
      children: []
    }
  end

  @doc """
  Returns a `:native_view` node that renders a platform-native component.

  `module` must implement the `Mob.Component` behaviour and be registered
  on the native side via `MobNativeViewRegistry`. The `:id` must be unique
  per screen — a duplicate raises at render time.

  All other props are passed to `mount/2` and `update/2` on the component.

  ## Example

      Mob.UI.native_view(MyApp.ChartComponent, id: :revenue_chart, data: @points)

  """
  @spec native_view(module(), keyword() | map()) :: map()
  def native_view(module, props \\ [])
  def native_view(module, props) when is_list(props), do: native_view(module, Map.new(props))

  def native_view(module, %{} = props) when is_atom(module) do
    %{type: :native_view, props: Map.put(props, :module, module), children: []}
  end

  @doc """
  Returns a `:canvas` leaf node — declarative 2D drawing surface backed
  by SwiftUI `Canvas` on iOS and Jetpack Compose `Canvas` on Android.

  Coordinates are canvas-local in points/dp, top-left origin.

  ## Props

    * `:width` — canvas width in pt/dp (required)
    * `:height` — canvas height in pt/dp (required)
    * `:draw` — list of op maps (required); construct via `Mob.Canvas.line/5`,
      `Mob.Canvas.circle/4`, etc., or as raw maps with an `:op` key

  Color tokens inside draw ops are resolved against the active theme
  by `Mob.Renderer` before serialisation, exactly like top-level color
  props on text/button/etc.

  ## Example

      import Mob.UI
      import Mob.Canvas

      canvas(width: 240, height: 240, draw: [
        circle(120, 120, 115, color: :surface_outline, width: 2),
        line(60, 60, 60, 180, color: :primary, width: 8, cap: :round),
        line(60, 180, 180, 180, color: :primary, width: 8, cap: :round),
        line(60, 60, 180, 180, color: :primary, width: 8, cap: :round)
      ])

  See `Mob.Canvas` for the full op list and modifier reference.
  """
  @spec canvas(keyword() | map()) :: map()
  def canvas(props) when is_list(props), do: canvas(Map.new(props))

  def canvas(%{} = props) do
    %{
      type: :canvas,
      props: Map.take(props, [:width, :height, :draw]),
      children: []
    }
  end

  @doc """
  Returns a `:gpu_view` leaf node — a fragment-shader-driven GPU surface
  backed by `MTKView` + Metal on iOS. The native side compiles the
  supplied shader (Metal Shading Language) into a render pipeline, binds
  the supplied uniforms in declaration order at fragment buffer slot 0,
  and renders a full-screen quad at the display refresh rate.

  Android support (`GLSurfaceView` + GLES 3.0) is not in v1.

  ## Props

    * `:id` — required atom that identifies the GPU view across re-renders
      (so the native side keeps the same Metal pipeline / texture cache).
    * `:width` / `:height` — pt/dp, required.
    * `:shader` — either a string of Metal Shading Language source (iOS),
      or a map `%{ios: "...MSL..."}` (escape hatch — same as the string
      form; the map form exists so future platforms can be added without
      breaking the API).
    * `:uniforms` — an **ordered list of values** packed into the shader's
      `Uniforms` struct in declaration order. Each element is one of:
      * a number — `float` (or `uint` if integer-typed at the BEAM level)
      * a 2-element list `[a, b]` — `float2`
      * a 4-element list `[a, b, c, d]` — `float4`
      (`float3` deliberately not supported in v1 — its 16-byte
      alignment with 12-byte size makes the layout API messier than
      it's worth here.)

  Shader compile errors are caught natively and surfaced as a translucent
  overlay on top of the GpuView with the error message.

  ## Why a list, not a map

  Elixir map iteration order is **not stable** across runtimes or map
  sizes — `%{a: 1, b: 2, c: 3}` can iterate in any order. The natural
  MSL layout for a `Uniforms` struct is positional, so we mirror that
  on the BEAM side. List position 0 → first struct member, etc.

  A map form is still accepted as a backward-compat fallback but will
  pack in whatever order the runtime decides, so the shader-side struct
  has to match an unstable order — not recommended.

  ## Example — Mandelbrot at the display's refresh rate

      @shader File.read!("priv/shaders/mandelbrot.metal")

      Mob.UI.gpu_view(
        id: :mandelbrot,
        width: 350,
        height: 350,
        shader: @shader,
        # MSL: struct Uniforms { float2 center; float zoom; uint max_iter; };
        uniforms: [[cx, cy], zoom, max_iter]
      )

  ## What the framework auto-provides

  The host emits a built-in vertex shader that draws a full-screen quad
  and produces a `VertexOut { float4 position [[position]]; float2 uv; }`.
  Your fragment shader receives that as `[[stage_in]]` and reads
  `in.uv` (0..1 across the view) plus the user uniforms at buffer slot 0.
  Don't redeclare `VertexOut`, `vertex_main`, or the metal_stdlib include
  in your shader — the host prepends them.

  ## Required fragment entry point

  Your shader must export `fragment_main`:

      fragment half4 fragment_main(VertexOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(0)]]) { ... }
  """
  @spec gpu_view(keyword() | map()) :: map()
  def gpu_view(props) when is_list(props), do: gpu_view(Map.new(props))

  def gpu_view(%{} = props) do
    %{
      type: :gpu_view,
      props:
        Map.take(props, [
          :id,
          :width,
          :height,
          :shader,
          :uniforms,
          :on_tap,
          :on_drag,
          :on_pinch
        ]),
      children: []
    }
  end

  @sheet_detents [:medium, :large]
  @sheet_color_props [:background, :scrim, :drag_indicator_color]
  @sheet_dimension_props [
    :drag_indicator_width,
    :drag_indicator_height,
    :drag_indicator_rail_height
  ]
  @sheet_indicator_props [:drag_indicator_color | @sheet_dimension_props]
  @sheet_style_props [:corner_radius | @sheet_color_props ++ @sheet_dimension_props]

  # `nil`, `true`, and `false` are atoms too — excluded explicitly so a
  # theme-token prop doesn't silently pass one through to native code that
  # expects a real color/radius and crashes trying to read one (the iOS
  # NSNull.longLongValue failure mode this guard exists to prevent).
  defguardp is_theme_token(value) when is_atom(value) and value not in [nil, true, false]

  @doc """
  Returns a `:sheet` node — a native modal bottom sheet (iOS `.sheet`,
  Android Material 3 `ModalBottomSheet`) that composes ordinary Mob nodes
  as its content.

  `children` is one child node or a list of them.

  ## Props

    * `:detents` — nonempty, duplicate-free subset of `[:medium, :large]`,
      or the exclusive content-height detent `[:content]` /
      `[{:content, max_height: number}]`. Defaults to `[:medium, :large]`.
      `:medium` alone rejects expansion to full height; `:large` alone skips
      the half-height stop. A content detent wraps intrinsic content and caps
      overflow in an internally scrolling body.
    * `:on_dismiss` — `{pid, tag}`, delivered as `handle_info({:dismiss, tag}, socket)`
      exactly once when the sheet is dismissed (swipe-down, back gesture,
      or outside tap) — the same `{atom, tag}` wire shape as `on_focus`,
      `on_blur`, `on_submit`, and `on_select` elsewhere in `Mob.UI`.
    * `:background` — container color: a theme token atom or a
      `0x00000000..0xFFFFFFFF` ARGB integer.
    * `:scrim` — dimming-layer color, same value shape as `:background`.
      **iOS cannot honor this exactly** — see the note below.
    * `:corner_radius` — top-corner radius: a theme radius token atom or
      a non-negative number.
    * `:drag_indicator_color`, `:drag_indicator_width`,
      `:drag_indicator_height`, `:drag_indicator_rail_height` — a custom
      drag-indicator capsule. All four are required together, or omit
      all four for the platform default indicator. Width and height must
      be positive; rail height must be at least the indicator height (the
      rail is the invisible touch target the visible capsule sits inside).
    * `:ios` / `:android` — per-platform overrides. Each accepts only the
      style keys above (not `:detents` or `:on_dismiss`); see `Mob.Renderer`'s
      "Platform blocks" section for the general override mechanism.

  ## Example

      Mob.UI.sheet(
        Mob.UI.text(text: "Hello from the sheet"),
        detents: [:medium, :large],
        on_dismiss: {self(), :dismiss_sheet},
        background: :surface,
        scrim: 0x33000000,
        corner_radius: 10,
        drag_indicator_color: :muted,
        drag_indicator_width: 36,
        drag_indicator_height: 5,
        drag_indicator_rail_height: 22,
        ios: %{corner_radius: 10},
        android: %{corner_radius: 28}
      )

  ## Platform limitation: scrim opacity on iOS

  Android applies `:scrim` exactly — the sheet's dimming layer is drawn
  with the requested color, alpha included. iOS's `.sheet` presentation
  owns its dimming layer and does not expose an API to configure its
  opacity; supported SwiftUI APIs leave it system-black at a fixed,
  non-configurable alpha. There is no workaround that doesn't involve
  private view-hierarchy manipulation, which this framework does not do.
  If your design depends on exact scrim opacity, treat it as
  Android-only and expect iOS to look slightly different.
  """
  @spec sheet(map() | [map()], keyword() | map()) :: map()
  def sheet(children, opts \\ [])
  def sheet(children, opts) when is_list(opts), do: sheet(children, Map.new(opts))

  def sheet(children, %{} = opts) do
    detents = opts |> Map.get(:detents, @sheet_detents) |> normalize_sheet_detents!()
    validate_on_dismiss!(Map.get(opts, :on_dismiss))
    validate_style!(opts)
    validate_platform_override!(opts, :ios)
    validate_platform_override!(opts, :android)
    validate_indicator_completeness!(opts)

    %{
      type: :sheet,
      props: Map.put(opts, :detents, detents),
      children: List.wrap(children)
    }
  end

  @doc false
  @spec normalize_sheet_detents!(term()) :: [atom() | map()]
  def normalize_sheet_detents!([:content]), do: [%{type: :content}]

  def normalize_sheet_detents!([{:content, options}]) when is_list(options) do
    if Keyword.keyword?(options) do
      case Keyword.fetch(options, :max_height) do
        {:ok, maximum} when is_number(maximum) and maximum > 0 and length(options) == 1 ->
          [%{type: :content, max_height: maximum}]

        _other ->
          invalid_sheet_detents!()
      end
    else
      invalid_sheet_detents!()
    end
  end

  def normalize_sheet_detents!([%{type: :content} = detent]) when map_size(detent) == 1,
    do: [detent]

  def normalize_sheet_detents!([%{type: :content, max_height: maximum} = detent])
      when map_size(detent) == 2 and is_number(maximum) and maximum > 0,
      do: [detent]

  def normalize_sheet_detents!(detents) when is_list(detents) and detents != [] do
    if Enum.all?(detents, &(&1 in @sheet_detents)) and
         length(detents) == length(Enum.uniq(detents)) do
      detents
    else
      invalid_sheet_detents!()
    end
  end

  def normalize_sheet_detents!(_detents), do: invalid_sheet_detents!()

  defp invalid_sheet_detents! do
    raise ArgumentError,
          "Mob.UI.sheet :detents must be unique :medium/:large values or one " <>
            ":content detent with an optional positive :max_height"
  end

  defp validate_on_dismiss!(nil), do: :ok
  defp validate_on_dismiss!({pid, tag}) when is_pid(pid) and is_atom(tag), do: :ok

  defp validate_on_dismiss!(other) do
    raise ArgumentError, "Mob.UI.sheet :on_dismiss must be {pid, atom}, got: #{inspect(other)}"
  end

  defp validate_style!(opts) do
    Enum.each(@sheet_style_props, fn key ->
      if Map.has_key?(opts, key), do: validate_style_value!(key, Map.fetch!(opts, key))
    end)
  end

  defp validate_style_value!(:corner_radius, value), do: validate_radius!(:corner_radius, value)

  defp validate_style_value!(key, value) when key in @sheet_color_props,
    do: validate_color!(key, value)

  defp validate_style_value!(key, value) when key in @sheet_dimension_props,
    do: validate_dimension!(key, value)

  defp validate_color!(_key, value) when is_theme_token(value), do: :ok
  defp validate_color!(_key, value) when is_integer(value) and value in 0..0xFFFFFFFF, do: :ok

  defp validate_color!(key, value) do
    raise ArgumentError,
          "Mob.UI.sheet #{inspect(key)} must be a theme-token atom or a " <>
            "0x00000000..0xFFFFFFFF ARGB integer, got: #{inspect(value)}"
  end

  defp validate_radius!(_key, value) when is_theme_token(value), do: :ok
  defp validate_radius!(_key, value) when is_number(value) and value >= 0, do: :ok

  defp validate_radius!(key, value) do
    raise ArgumentError,
          "Mob.UI.sheet #{inspect(key)} must be a radius token atom or a non-negative number, " <>
            "got: #{inspect(value)}"
  end

  defp validate_dimension!(_key, value) when is_number(value) and value >= 0, do: :ok

  defp validate_dimension!(key, value) do
    raise ArgumentError,
          "Mob.UI.sheet #{inspect(key)} must be a non-negative number, got: #{inspect(value)}"
  end

  defp validate_platform_override!(opts, platform_key) do
    case Map.get(opts, platform_key) do
      nil ->
        :ok

      %{} = override ->
        invalid = Map.keys(override) -- @sheet_style_props

        unless invalid == [] do
          raise ArgumentError,
                "Mob.UI.sheet #{inspect(platform_key)} override contains unsupported keys: " <>
                  "#{inspect(invalid)} (supported: #{inspect(@sheet_style_props)})"
        end

        Enum.each(override, fn {key, value} -> validate_style_value!(key, value) end)

      other ->
        raise ArgumentError,
              "Mob.UI.sheet #{inspect(platform_key)} must be a map, got: #{inspect(other)}"
    end
  end

  # If any custom drag-indicator prop is supplied, all four are required —
  # a partial override has no sensible native default to fall back to for
  # the missing geometry. Checked against the base opts AND against the
  # base merged with each platform override, since `Mob.Renderer`'s
  # platform-block flattening (`ios:`/`android:`) composes an override on
  # top of the base at render time — a base with zero indicator props plus
  # an `ios: %{drag_indicator_color: ...}` override would otherwise pass
  # validation here but flatten to an incomplete set on iOS, which native
  # silently treats as "no custom indicator" instead of erroring.
  # validate_style! already ran by the time this is called, so
  # width/height/rail_height are confirmed numeric here; the ordering
  # matters because Elixir's structural `>` never raises across types (an
  # atom silently compares greater than any number), so the
  # positivity/rail-height checks below would rubber-stamp a bad value
  # instead of catching it if type-checking hadn't already happened.
  defp validate_indicator_completeness!(opts) do
    validate_merged_indicator_completeness!(opts, "base props")

    case Map.get(opts, :ios) do
      %{} = override ->
        validate_merged_indicator_completeness!(Map.merge(opts, override), ":ios override")

      _ ->
        :ok
    end

    case Map.get(opts, :android) do
      %{} = override ->
        validate_merged_indicator_completeness!(Map.merge(opts, override), ":android override")

      _ ->
        :ok
    end
  end

  defp validate_merged_indicator_completeness!(merged, context) do
    present = Enum.filter(@sheet_indicator_props, &Map.has_key?(merged, &1))

    cond do
      present == [] ->
        :ok

      length(present) == length(@sheet_indicator_props) ->
        validate_indicator_geometry!(merged)

      true ->
        missing = @sheet_indicator_props -- present

        raise ArgumentError,
              "Mob.UI.sheet: a custom drag indicator requires all of " <>
                "#{inspect(@sheet_indicator_props)} (checking #{context}), " <>
                "missing: #{inspect(missing)}"
    end
  end

  defp validate_indicator_geometry!(opts) do
    width = Map.fetch!(opts, :drag_indicator_width)
    height = Map.fetch!(opts, :drag_indicator_height)
    rail = Map.fetch!(opts, :drag_indicator_rail_height)

    unless width > 0 do
      raise ArgumentError,
            "Mob.UI.sheet :drag_indicator_width must be positive, got: #{inspect(width)}"
    end

    unless height > 0 do
      raise ArgumentError,
            "Mob.UI.sheet :drag_indicator_height must be positive, got: #{inspect(height)}"
    end

    unless rail >= height do
      raise ArgumentError,
            "Mob.UI.sheet :drag_indicator_rail_height (#{inspect(rail)}) must be >= " <>
              ":drag_indicator_height (#{inspect(height)})"
    end
  end
end
