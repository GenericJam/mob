# Zoomable images zoom natively, and fill the space they are offered
- Date: 2026-10-19
- Status: accepted

## Context

An app showing one photo full screen wants pinch to zoom, double tap to zoom
and pan while zoomed (Bezalel's image viewer). Mob already reports `on_pinch`
and `on_double_tap` to Elixir, but a zoom driven from the screen would need a
render round-trip per finger movement, and Android had no working pinch event.

## Decision

- `zoomable: true` on `:image` (with `max_zoom`, default 4.0, and
  `double_tap_zoom`, default 2.5) is handled entirely by the native renderer.
  No event reaches the screen.
- iOS: a `UIScrollView` zooming a `UIImageView` (`ios/MobZoomableImage.swift`),
  not SwiftUI's `MagnifyGesture`. The scroll view already zooms about the
  pinch, clamps panning to its content plus the centring insets and bounces
  the zoom. Its pan recognizer is enabled only while zoomed in, which is how a
  one-finger drag at 1x reaches a parent scroll or pager. Panning does not
  rubber-band (`bounces = false`), so the picture's edge never comes inside
  the frame's; Android clamps the same way. Local files load through
  `MobImageCache`, URLs through `URLSession.shared` (the shared `URLCache`
  AsyncImage uses), decoded off the main thread.
- Android (mob_new's `MobBridge.kt`): `graphicsLayer` scale and translation
  driven by one `pointerInput` loop placed before the layer, so pointer
  positions are in the frame's untransformed space. One-finger moves are
  consumed only while zoomed in and past touch slop; downs and ups are never
  consumed, so an outer `on_tap` clickable still sees taps. Double tap is
  detected in the same loop rather than with `detectTapGestures`, which
  consumes the down and would starve that clickable.
- A zoomable image **fills the space it is offered**, because that space is
  the zoom viewport: sized like a plain image, a landscape photo on a portrait
  screen could only be zoomed inside its letterboxed strip. An axis with no
  bound (the height inside a vertical scroll) follows the picture's aspect
  ratio. A non-zoomable image keeps its old sizing.
- Zoom state is keyed on `src`: a new picture starts at 1x.

## Consequences

- A zoomable image in a column with siblings after it takes the remaining
  height on Android (Compose measures children in order), while SwiftUI's
  VStack shares it. Authors give it `width`/`height`, a weight, or the whole
  screen, which is what a viewer does anyway.
- `on_double_tap` / `on_pinch` on a zoomable image compete with the native
  gestures; the guide says not to combine them.
- Android decodes the picture at up to 4096 px on its long side, never
  upscaled, so zooming in shows detail; a full-size photo costs up to
  4096 x 4096 x 4 bytes while shown.
