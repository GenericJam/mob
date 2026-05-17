defmodule Mob.Canvas do
  @moduledoc """
  Drawing-op constructors for `Mob.UI.canvas/1`.

  Each function returns a plain map describing one draw operation. The
  canvas widget takes a `:draw` list of these and renders them in order.
  Color values can be theme tokens (e.g. `:primary`, `:on_surface`) or
  raw strings ("#ff0000") — they are resolved by `Mob.Renderer` against
  the active theme before serialisation to the native side.

  ## Coordinate system (important — read this once)

  All coordinates are **canvas-local logical units**, top-left origin.
  The unit is whatever the host app's `<Canvas>` component declared
  via the `width` and `height` props on the canvas — a draw op at
  `(width / 2, height / 2)` lands in the dead centre of the rendered
  canvas regardless of the canvas's actual on-screen pixel size.

  This deliberately differs from raw Compose `DrawScope.size` (which
  is in pixels) and from raw SwiftUI `Canvas` (which is in points).
  The renderer multiplies every coordinate by
  `(actual_pixels / declared_logical_units)` per axis so callers
  don't have to thread density and parent-constraint information
  through every draw call.

  Practical consequence: a YOLO model that outputs bbox coords in
  `0..640` can be drawn directly on a `<Canvas width=640 height=640>`
  and the boxes will line up with the underlying preview image
  regardless of the actual on-screen size or device density.

  See "Implementing the renderer" below for the contract the host
  app's Kotlin / Swift `MobBridge` must honor.

  ## Implementing the renderer (host app's `MobBridge`)

  Mob ships no host-app code; each app's `MobBridge.kt` /
  `MobBridge.swift` contains the Canvas renderer. The viewport-scaling
  contract above is non-obvious and easy to get wrong — the original
  per-app implementations interpreted coordinates as raw pixels, which
  made bounding-box overlays drift on every device where 1 dp ≠ 1 px
  (i.e., every modern Android device). Reference recipe for Compose:

      @Composable
      private fun MobCanvas(node: MobNode, modifier: Modifier) {
        val width  = floatProp(node.props, "width")  ?: 0f
        val height = floatProp(node.props, "height") ?: 0f
        val ops    = ... // List<Map<String, Any?>>

        val sized = if (width > 0f && height > 0f)
          modifier.size(width.dp, height.dp) else modifier

        Canvas(modifier = sized) {
          // size.width / size.height are in PIXELS.
          val sx = if (width  > 0f) size.width  / width  else 1f
          val sy = if (height > 0f) size.height / height else 1f
          ops.forEach { op -> drawCanvasOp(op, sx, sy) }
        }
      }

  Every coord then passes through `coord * sx` / `coord * sy` in the
  draw step. Scalar sizes (stroke widths, circle radii, text sizes)
  use the average `(sx + sy) / 2` so they don't squash when the
  declared viewport is non-square.

  See `nxeigen_probe`'s
  `android/app/src/main/java/com/example/nxeigen_probe/MobBridge.kt`
  for the full working implementation.

  ## Op map equivalence

  Helpers and raw maps produce identical output. These are the same:

      Mob.Canvas.line(0, 0, 100, 100, color: :primary, width: 4)
      %{op: :line, x1: 0, y1: 0, x2: 100, y2: 100, color: :primary, width: 4}

  Use whichever you prefer; the renderer doesn't care.

  ## Available ops

    * `line/5`     — straight stroke between two points
    * `circle/4`   — circle (outline or filled)
    * `ellipse/5`  — ellipse with separate rx, ry
    * `arc/6`      — circular arc between two angles in degrees
    * `rect/5`     — rectangle (outline or filled, optional corner radius)
    * `path/2`     — sequence of points (open or closed; outline or filled)
    * `text/4`     — text at a point with anchor
    * `image/5`    — image from an asset name into a rect

  ## Common modifiers (accepted on every op where they make sense)

    * `:opacity`   — float 0.0–1.0
    * `:width`     — stroke width in points/dp (ignored on filled-only ops)
    * `:dash`      — list of [on, off] floats for dashed strokes, e.g. `[4, 4]`
    * `:cap`       — `:butt` | `:round` | `:square` (line/arc/path)
    * `:join`      — `:miter` | `:round` | `:bevel` (path/rect outline)
    * `:fill`      — boolean (circle/ellipse/rect/path); default false (stroke)

  ## Text-specific

    * `:weight`    — `:thin` | `:light` | `:regular` | `:medium` | `:semibold` | `:bold`
    * `:family`    — string font family name; platform default if omitted
    * `:anchor`    — `:start` | `:center` | `:end` (horizontal); default `:start`
  """

  @line_opts [:width, :cap, :dash, :opacity]
  @circle_opts [:width, :fill, :dash, :opacity]
  @ellipse_opts [:width, :fill, :dash, :opacity]
  @arc_opts [:width, :cap, :dash, :opacity]
  @rect_opts [:width, :fill, :radius, :join, :dash, :opacity]
  @path_opts [:width, :fill, :closed, :cap, :join, :dash, :opacity]
  @text_opts [:weight, :family, :anchor, :opacity]
  @image_opts [:opacity]

  @doc """
  Stroke a line from (x1, y1) to (x2, y2).

      Mob.Canvas.line(0, 0, 100, 100, color: :primary, width: 4, cap: :round)
  """
  @spec line(number(), number(), number(), number(), keyword() | map()) :: map()
  def line(x1, y1, x2, y2, opts \\ []) do
    base = %{op: :line, x1: x1, y1: y1, x2: x2, y2: y2, color: required(opts, :color, :line)}
    Map.merge(base, take(opts, @line_opts))
  end

  @doc """
  Draw a circle. Defaults to stroke; pass `fill: true` for a filled disc.

      Mob.Canvas.circle(120, 120, 60, color: :primary)
      Mob.Canvas.circle(120, 120, 60, color: :primary, fill: true)
  """
  @spec circle(number(), number(), number(), keyword() | map()) :: map()
  def circle(x, y, r, opts \\ []) do
    base = %{op: :circle, x: x, y: y, r: r, color: required(opts, :color, :circle)}
    Map.merge(base, take(opts, @circle_opts))
  end

  @doc """
  Draw an ellipse with separate horizontal and vertical radii.

      Mob.Canvas.ellipse(100, 80, 60, 30, color: :primary, fill: true)
  """
  @spec ellipse(number(), number(), number(), number(), keyword() | map()) :: map()
  def ellipse(x, y, rx, ry, opts \\ []) do
    base = %{
      op: :ellipse,
      x: x,
      y: y,
      rx: rx,
      ry: ry,
      color: required(opts, :color, :ellipse)
    }

    Map.merge(base, take(opts, @ellipse_opts))
  end

  @doc """
  Draw a circular arc centered at (x, y), radius r, from `start_deg`
  sweeping clockwise to `end_deg`. 0° points to the right, 90° points
  down (matching SwiftUI / Compose conventions).

      Mob.Canvas.arc(100, 100, 50, 0, 90, color: :primary, width: 2)
  """
  @spec arc(number(), number(), number(), number(), number(), keyword() | map()) :: map()
  def arc(x, y, r, start_deg, end_deg, opts \\ []) do
    base = %{
      op: :arc,
      x: x,
      y: y,
      r: r,
      start_deg: start_deg,
      end_deg: end_deg,
      color: required(opts, :color, :arc)
    }

    Map.merge(base, take(opts, @arc_opts))
  end

  @doc """
  Draw a rectangle. Defaults to stroke; pass `fill: true` for filled.
  `radius:` rounds the corners (single value, all four corners).

      Mob.Canvas.rect(10, 10, 100, 50, color: :primary, fill: true, radius: 8)
  """
  @spec rect(number(), number(), number(), number(), keyword() | map()) :: map()
  def rect(x, y, w, h, opts \\ []) do
    base = %{op: :rect, x: x, y: y, w: w, h: h, color: required(opts, :color, :rect)}
    Map.merge(base, take(opts, @rect_opts))
  end

  @doc """
  Draw a path through a list of points. Points are 2-element lists or
  2-tuples; tuples are normalised to lists for JSON serialisation.

  Closed paths (`closed: true`) are wrapped back to the first point.
  Filled paths (`fill: true`) are filled regardless of `:closed`.

      Mob.Canvas.path([{0, 0}, {100, 0}, {50, 80}], color: :primary, closed: true)
  """
  @spec path([{number(), number()} | [number()]], keyword() | map()) :: map()
  def path(points, opts \\ []) when is_list(points) do
    base = %{
      op: :path,
      points: Enum.map(points, &normalize_point/1),
      color: required(opts, :color, :path)
    }

    Map.merge(base, take(opts, @path_opts))
  end

  @doc """
  Draw text at (x, y). The anchor controls horizontal alignment of the
  text relative to x; vertical baseline is ascender (text grows downward
  from y, matching SwiftUI/Compose Canvas defaults).

      Mob.Canvas.text(120, 50, "Hello", color: :on_surface, size: 18, anchor: :center)
  """
  @spec text(number(), number(), String.t(), keyword() | map()) :: map()
  def text(x, y, content, opts \\ []) when is_binary(content) do
    base = %{
      op: :text,
      x: x,
      y: y,
      text: content,
      color: required(opts, :color, :text),
      size: required(opts, :size, :text)
    }

    Map.merge(base, take(opts, @text_opts))
  end

  @doc """
  Draw an image into the rect at (x, y, w, h). `source` is an asset
  name resolved by the platform (e.g. an iOS asset catalog name or
  Android drawable name).

      Mob.Canvas.image(0, 0, 100, 100, "logo")
  """
  @spec image(number(), number(), number(), number(), String.t(), keyword() | map()) :: map()
  def image(x, y, w, h, source, opts \\ []) when is_binary(source) do
    base = %{op: :image, x: x, y: y, w: w, h: h, source: source}
    Map.merge(base, take(opts, @image_opts))
  end

  # ── Internals ─────────────────────────────────────────────────────────

  defp required(opts, key, op) do
    case fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError, "Mob.Canvas.#{op}/N missing required option `:#{key}`"
    end
  end

  defp take(opts, keys) when is_list(opts) do
    opts |> Map.new() |> Map.take(keys)
  end

  defp take(%{} = opts, keys), do: Map.take(opts, keys)

  defp fetch(opts, key) when is_list(opts), do: Keyword.fetch(opts, key)
  defp fetch(%{} = opts, key), do: Map.fetch(opts, key)

  defp normalize_point({x, y}), do: [x, y]
  defp normalize_point([x, y]), do: [x, y]

  defp normalize_point(other) do
    raise ArgumentError,
          "Mob.Canvas.path expected a {x, y} tuple or [x, y] list, got: #{inspect(other)}"
  end
end
