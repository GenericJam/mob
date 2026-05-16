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

  Call `Mob.Camera.start_preview/2` before mounting this component, and
  `Mob.Camera.stop_preview/1` when done.

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
end
