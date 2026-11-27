# An uncoloured Text defaults to `:on_surface` in the renderer, not in native

- Date: 2026-11-27
- Status: accepted

## Context

A `:text` or `:icon` node with no `text_color` was coloured by each platform on
its own terms (MOB-567):

- iOS: `Color.primary` (`MobRootView.swift`, the `.label` and `.icon` cases),
  which follows the system light/dark appearance, not `Mob.Theme`.
- Android: Compose's `LocalContentColor`. Mob installs `MaterialTheme` with a
  colour scheme mapped from `Mob.Theme` but no `Surface`, so outside a Material
  container that provides content colour the default is black; an icon with
  `tint = Color.Unspecified` draws the vector's own colour.

So a dark Mob theme on a light-mode phone drew black labels on dark surfaces
(MishkaCard's string `title`, found in the mob_mishka iOS tour), and Android
was dark-on-dark whatever the phone's setting.

## Decision

`Mob.Renderer`'s `@component_defaults` gives `:text` and `:icon`
`text_color: :on_surface`, the same token `:text_field` already defaulted to.
Both platforms then receive a resolved ARGB colour from the active theme and
neither native renderer's text drawing changes. The one native change is the
iOS root paint under Consequences, which keeps the default readable.

The style merge moved ahead of the defaults (`merge_style/1` in `prepare/4`):
inline props > `%Mob.Style{}` props > component defaults. Before, defaults were
merged into the inline props and the style under both, so this default would
have overridden every style that sets `text_color` on a Text. The same order
already broke a style's `background` / `text_color` on a `:button`.

`:on_surface` rather than `:on_background`: cards, sheets and rows are
surfaces, and most themes give both the same value (`Mob.Theme` defaults both to
`:gray_100`). Text straight on a `:background` page in a theme where the two
differ still needs `text_color: :on_background`.

## Consequences

- No node inherits text colour from a parent any more, on either platform. On
  iOS none did (the explicit `Color.primary` overrode the environment). On
  Android a Text inside a `ModalBottomSheet` took `contentColorFor(container)`,
  and one under the tab bar's `Scaffold` took `onBackground`; both now take
  `:on_surface`. That differs only when the sheet's `background` is a
  non-surface theme colour such as `:primary` (such Text needs
  `text_color: :on_primary`), or when a theme's `on_background` and
  `on_surface` differ (no shipped theme's do).
- **iOS: the root paints the theme's background.** `Color.primary` was
  readable on the system background whatever the theme; `:on_surface` is not
  when the theme and the phone's appearance disagree (a dark theme's light
  text on a light-mode phone's white), and the iOS root used to show the
  system background under a screen with no `background`. So `MobRootView`
  now paints the theme's `background` behind every screen, as Android's
  MainActivity paints `colorScheme.background`. `nif_set_theme` reads
  `background` from the palette `Mob.Theme.set/1` already pushed and hands
  it to every window's view model (`MobViewModel.themeBackground`), so a
  theme change or an adaptive theme's light/dark flip repaints live. A `:list`
  with no `background` is clear and shows the same paint.
- **A `:sheet` defaults to `background: :surface`** in `@component_defaults`
  rather than being painted natively. A sheet is presented above the root,
  so the root paint does not reach it: iOS drew one with no `background` on
  the system sheet material, Android on Material's `surfaceContainerLow`
  (`BottomSheetDefaults.ContainerColor`), which Mob's colour scheme does not
  set. One renderer default gives both platforms the theme's surface, the
  fill `:on_surface` is meant for, and an explicit `background` still wins.
  The cost: no theme gets the system sheet material any more, the Liquid
  Glass sheet on iOS 26 included, glass themes too, and there is no prop that
  asks for it back (`background: :transparent` is see-through, not the
  material). That material follows the phone's appearance, not the theme,
  which is the mismatch this record removes; a glass theme that wants a
  translucent sheet would need a sheet-level `glass` flag, not done here.
- `:button` draws its own label from its own `text_color` and is a leaf, so no
  Text sits inside a button's content colour.
- A composite that wanted "whatever the platform's default is" can no longer
  get it by leaving `text_color` unset; it can pass an explicit colour.
