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
end
