# iOS anchored panels: measure the panel, not its cap, and place it in window coordinates

- Date: 2026-11-27
- Status: accepted
- Issue: MOB-563 (child of MOB-561). Follow-ups: MOB-564, MOB-574
- Amends: `2026-09-12-ios-anchored-is-a-root-overlay.md` (corrected in place)

## Context

On iOS every open `:anchored` panel (tooltip, popover, preview card) sat in
the top-left corner, under the status bar, and stayed there while its trigger
scrolled away. When the trigger was off screen, the panel was clipped at x=0
instead. Android was not affected. There were two separate causes in
`ios/MobAnchored.swift`.

1. **The measured size was the cap, not the panel.** `MobAnchoredPanel`
   measured `panelSize` with a `GeometryReader` background attached *outside*
   `.frame(maxWidth:maxHeight:)`. A max-only flexible frame takes the size it
   is offered, clamped to the max, and ignores its child's size. The root
   offers the whole window, so every panel measured as the window minus the
   edge padding (424 x 878 pt on an iPhone 18 Pro Max). No side ever fitted,
   so nothing flipped. While the anchor was on screen, the clamp then pinned
   the panel to the top-left. While it was off screen the centred x was about
   `anchor.midX - 212`, which is negative.
2. **The status bar was counted twice and the home indicator not at all.** The
   host's `GeometryReader` lived inside the root, which respects the top safe
   area and ignores the bottom and horizontal ones. `GeometryProxy.safeAreaInsets`
   reports the insets the reader's frame already *excludes*. On device it read
   `top: 62, bottom: 0` for a frame that already started at y=62. Adding that
   to the edge padding put the clamp 70 pt below the container top, which is
   y=132 in the window. Top-side panels flipped early. Nothing kept a panel
   off the home indicator.

## Decision

- **Measure the panel, and cap it with a layout that has the panel's size.**
  The max-only `.frame` is replaced by `MobAnchoredCap`, a small `Layout`. It
  offers the panel at most `panel_max_width`/`panel_max_height` (by default the
  window less the edges) and takes the panel's own size. That is exactly what
  Android's `Modifier.widthIn(max)/heightIn(max)` inside the `Popup` does. The
  `GeometryReader` background measures it. The other option was to move the
  measurement inside the old frame. It would have measured the right size, but
  the frame would still have been larger than the panel. Then where the panel
  sits inside that frame, and so where it lands, would depend on the frame's
  alignment, which flips under right-to-left. With the cap layout the
  measured, offset and drawn rectangle is the same one.
- **Place panels in window coordinates, padded by the window's own insets.**
  The host's `GeometryReader` now has `.ignoresSafeArea(.container)`. It spans
  the window, anchors resolve in window coordinates, and "anchor on screen"
  means on the display. That is the frame Android's provider works in (the
  real display, plus `safeDrawing` per edge). The ignore is `.container` and
  not all regions, so the keyboard region is still respected: with the
  keyboard up the host ends at the keyboard's top, and a panel flips or clamps
  above it, as Android's `safeDrawing`, which includes the IME, does. A reader
  that ignores the container safe area reports zero insets, and no SwiftUI view
  inside the root can see the home indicator, because the root ignores the
  bottom edge. So the insets come from UIKit:
  `MobHostingController.viewSafeAreaInsetsDidChange` writes `view.safeAreaInsets`
  to the new `@Published MobViewModel.windowSafeArea`, and `MobRootView`
  passes it to `MobAnchoredPanelHost`. With the keyboard up this pads 34 pt for
  a home indicator the keyboard already covers; that costs nothing. The
  arithmetic now takes `UIEdgeInsets` and uses `left`/`right`, because it works
  in absolute coordinates and does its own RTL mirroring. Android's
  `insets.getLeft(density, ld)` is absolute too.
- **The anchor preference needed no change.** It re-resolves as the page
  scrolls. Measured with `Mob.Test.element_frames` at several `scroll_to`
  offsets, every panel stays `side_offset` from its own trigger.
- The position arithmetic itself is unchanged and still matches Android's
  `MobAnchoredPositionProvider` line for line.

## Verified on device (iPhone 18 Pro Max simulator, mishka_ios_demo)

Trigger-to-panel gaps came from `element_frames` at five or more scroll offsets
per page. Popovers were opened with real touches (agent-device), and preview
cards with `Mob.Test.tap` on their hold tag.

- Every tooltip ends up `side_offset` from its trigger: 6, or 16 for
  `align-end`, on all four sides.
- The `:top` popover flips to `:bottom` once there is no room above it (gap 12).
- A clamped panel stops at y=70, which is the 62 pt status bar plus 8.
- Preview cards sit 8 pt (bottom) or 14 pt (top) from their trigger.

Before the fix, the same probe measured gaps of 50 to 850 pt, every on-screen
panel at (8, 132), and off-screen panels at x=-152 to -390.

## Consequences

- **Still wrong until MOB-564 lands (the iOS Column always fills).** A panel
  whose content holds a plain `Column` measures as wide as the cap on iOS
  (424 pt), where Android hugs it. This covers `MishkaPopover.panel/2`'s inner
  Column and the tooltip arrow's `pile/1`. Three visible effects follow, and
  all three should clear once MOB-564 makes a Column hug unless `fill_width`
  is set:
  - Popovers and preview cards with `side: :right` cannot fit either side of
    their trigger, so the clamp lays them over it.
  - The popover beak and the tooltip arrow are centred on a 424 pt panel, not
    on the trigger. That is the web's `left: 50%` applied to the wrong width.
  - Wide panels hug the leading edge.

  The mob_mishka beak wrapper (a `fill_width` Box in `mishka_popover.ex`
  `aligned/2`) would make arrowed popovers cap-wide on Android too. That one
  has been handed to the mob_mishka composite fixes (MOB-571).
- **An off-screen trigger can still clip a wide panel at x=0.** `anchorOnScreen`
  gates the clamp on both axes. A centred panel wider than twice its trigger's
  midX goes negative once the trigger leaves the screen. On device, tooltip
  `style-plum` is 190.7 pt wide on a trigger at midX 60, which puts it at
  x=-35.3. Android shares the arithmetic. The per-axis gate that would fix this
  is MOB-574. It needs both platforms changed together and verified on Android,
  so it is deliberately left out here.
- `MobViewModel.windowSafeArea` is UIKit's reading for the window that hosts the
  model. Nothing is published before `viewIsAppearing`, because until then
  every window's controller shows the shared model. Without that guard, a
  second window's insets could land in the default window's model. A later
  model switch (`mobAdoptSceneModel`) publishes again.
- The keyboard case follows from SwiftUI's safe-area regions. No demo page puts
  an anchored panel next to a focused field (the combobox, select and
  autocomplete lists render in flow), so it has not been exercised on device.
- The dismiss scrim now spans the whole window, status bar band included, as
  Android's focusable `Popup` window does. A tap in that band therefore reports
  a dismiss too (not exercised on device).
- RTL is unverified on iOS, both before this change and after it. The cap
  adds no new direction dependence, since it is the panel's own size. What is
  still open is whether SwiftUI's `proxy[anchor]` and `.offset(x:)` are
  absolute or measured from the leading edge under right-to-left:
  - If absolute, the `left`/`right` insets are right.
  - If leading-relative, `side`/`align` are mirrored twice.

  One landscape RTL check on a device would settle it.
