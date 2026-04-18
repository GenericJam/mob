# Styling & Native Rendering

This page maps every Mob component and style prop to its native counterpart on iOS (SwiftUI) and Android (Jetpack Compose). Use it when you need to understand platform behaviour, look up what constraints apply, or reach for a platform-specific override.

Mob does not wrap a web renderer — you are writing directly to SwiftUI and Compose. That means native look-and-feel, native performance, and native constraints.

## Component → native widget

| Mob type | iOS (SwiftUI) | Android (Compose) |
|---|---|---|
| `:column` | `VStack(alignment: .leading, spacing: 0)` | `Column` |
| `:row` | `HStack(spacing: 0)` | `Row` |
| `:box` | `ZStack(alignment: .topLeading)` | `Box(contentAlignment = Alignment.TopStart)` |
| `:scroll` | `ScrollView` (vertical or horizontal) | `Column/Row` + `.verticalScroll` / `.horizontalScroll` |
| `:text` | `Text` | `Text` |
| `:button` | `Button` with `Text` label | `Button` with `Text` content |
| `:text_field` | `TextField` (SwiftUI `roundedBorder` style) | `TextField` (Material 3 filled style) |
| `:toggle` | `Toggle` | `Switch` inside a `Row` |
| `:slider` | `Slider` | `Slider` |
| `:divider` | `Divider` | `HorizontalDivider` |
| `:spacer` | `Spacer().frame(minWidth:, minHeight:)` | `Spacer(modifier = Modifier.size())` |
| `:progress` | `ProgressView()` (indeterminate spinner) | `CircularProgressIndicator` |
| `:image` | `AsyncImage` | `AsyncImage` (Coil) |
| `:lazy_list` | `ScrollView` + `LazyVStack` | `LazyColumn` |
| `:tab_bar` | `TabView` | `Scaffold` + `NavigationBar` |
| `:video` | `AVPlayerViewController` (UIKit wrapper) | Stub — requires ExoPlayer (see below) |

Platform docs:
- iOS SwiftUI: [developer.apple.com/documentation/swiftui/views-and-controls](https://developer.apple.com/documentation/swiftui/views-and-controls)
- Android Compose: [developer.android.com/develop/ui/compose/components](https://developer.android.com/develop/ui/compose/components)

---

## Common layout props

These props apply to every component via `nodeModifier` (Android) and view modifiers (iOS).

| Prop | iOS | Android | Notes |
|---|---|---|---|
| `background` | `.background(Color(argb))` | `Modifier.background(color)` | Drawn before padding so it fills the full area including padding space |
| `padding` | `.padding(EdgeInsets)` | `Modifier.padding(all =)` | Uniform on all sides |
| `padding_top/right/bottom/left` | `.padding(EdgeInsets)` | `Modifier.padding(top=, end=, bottom=, start=)` | Per-edge; falls back to `padding` for unset edges |
| `corner_radius` | `.clipShape(RoundedRectangle(cornerRadius:))` | `RoundedCornerShape(dp)` applied to background + clip | Applied after background, before children render |
| `fill_width` | `.frame(maxWidth: .infinity)` | `Modifier.fillMaxWidth()` | Defaults `true` on `:button`; `false` on others unless set |

iOS reference: [SwiftUI Layout](https://developer.apple.com/documentation/swiftui/layout-fundamentals)
Android reference: [Compose modifiers](https://developer.android.com/develop/ui/compose/modifiers)

### Ordering note

On both platforms, background is applied **before** padding so the color fills the full padded box. Corner radius clips after padding so the rounded mask covers the entire padded area. Changing this order visually by hand (e.g. via platform overrides) is unsupported and will produce inconsistent results across platforms.

---

## Typography props (`:text` and `:button`)

| Prop | iOS | Android | Values |
|---|---|---|---|
| `text_size` | `Font.system(size:)` | `fontSize =` | Number (sp/pt) or size token (`:base`, `:xl`, etc.) |
| `font_weight` | `Font.weight(_:)` | `fontWeight =` | `"bold"`, `"semibold"`, `"medium"`, `"regular"`, `"light"`, `"thin"` |
| `italic` | `.italic()` | `fontStyle = FontStyle.Italic` | Boolean |
| `text_align` | `.multilineTextAlignment()` + `.frame(alignment:)` | `textAlign =` | `"left"` / `"center"` / `"right"` (default: `"left"`) |
| `letter_spacing` | `.tracking(_:)` | `letterSpacing =` | Float (sp/pt) |
| `line_height` | `.lineSpacing(_:)` (derived as `(multiplier - 1.0) × size`) | `lineHeight =` | Float multiplier (e.g. `1.5` = 150%) |
| `font` | `Font.custom(name, size:)` | `FontFamily` loaded from assets | PostScript name on iOS; lowercase+underscore filename on Android. Falls back to system font if not found. |

iOS font reference: [Font (SwiftUI)](https://developer.apple.com/documentation/swiftui/font)
Android font reference: [Typography (Compose)](https://developer.android.com/develop/ui/compose/designsystems/custom#typography)

### line_height difference

SwiftUI's `.lineSpacing` adds *extra space between lines*, not total line height. Mob converts the multiplier to extra spacing as `(multiplier - 1.0) × font_size`, matching Compose's `lineHeight` behaviour as closely as possible. For very tight values (multiplier < 1.0) results will differ between platforms — test on both.

### Custom fonts

Drop `.ttf` / `.otf` files into `priv/fonts/` in your Mix project. `mix mob.deploy --native` copies them into the correct platform directories and patches `Info.plist` for iOS. Reference them by PostScript name:

```elixir
%{type: :text, props: %{text: "Hello", font: "Inter-Regular", text_size: :base}, children: []}
```

iOS requires the PostScript name (visible in Font Book → ⌘I). Android derives the resource name automatically from the filename (`Inter-Regular.ttf` → `inter_regular`), but Mob normalises the name before sending it to the NIF so you can use the same string on both platforms.

---

## Color props

| Prop | Applies to |
|---|---|
| `background` | All components |
| `text_color` | `:text`, `:button` |
| `color` | `:slider`, `:toggle`, `:progress`, `:divider` |
| `border_color` | `:text_field` |
| `placeholder_color` | `:text_field` |

Color values are resolved in this order:

1. **Semantic theme token** (`:primary`, `:surface`, `:on_surface`, etc.) — resolved via the active `Mob.Theme`
2. **Palette atom** (`:blue_500`, `:gray_200`, etc.) — resolved from the built-in palette
3. **Raw ARGB integer** (`0xFFFF5733`) — used as-is
4. **Unknown atom** — serialised as a string; the native side treats it as a no-op color

iOS color rendering: all ARGB integers are passed as `UIColor(argb:)` via the NIF and converted to `Color(_:)` in SwiftUI.
Android: ARGB integers are passed as `Long` and converted with `Color(long)`.

iOS reference: [Color (SwiftUI)](https://developer.apple.com/documentation/swiftui/color)
Android reference: [Color (Compose)](https://developer.android.com/develop/ui/compose/graphics/draw/brush)

---

## Input props (`:text_field`)

| Prop | iOS | Android |
|---|---|---|
| `keyboard: :default` | `.keyboardType(.default)` | `KeyboardType.Text` |
| `keyboard: :email` | `.keyboardType(.emailAddress)` | `KeyboardType.Email` |
| `keyboard: :number` | `.keyboardType(.numberPad)` | `KeyboardType.Number` |
| `keyboard: :decimal` | `.keyboardType(.decimalPad)` | `KeyboardType.Decimal` |
| `keyboard: :phone` | `.keyboardType(.phonePad)` | `KeyboardType.Phone` |
| `keyboard: :url` | `.keyboardType(.URL)` | `KeyboardType.Uri` |
| `return_key: :done` | `ToolbarItem` "Done" button dismisses keyboard | `ImeAction.Done` |
| `return_key: :next` | Keyboard stays open (next field focus handled by app) | `ImeAction.Next` |
| `return_key: :go` | n/a (treated as done) | `ImeAction.Go` |
| `return_key: :search` | n/a (treated as done) | `ImeAction.Search` |
| `return_key: :send` | n/a (treated as done) | `ImeAction.Send` |

iOS reference: [TextField (SwiftUI)](https://developer.apple.com/documentation/swiftui/textfield)
Android reference: [TextField (Compose)](https://developer.android.com/develop/ui/compose/text/user-input)

### iOS keyboard toolbar

iOS automatically shows a "Done" button in a keyboard toolbar above the keyboard for all text fields. This lets users dismiss the keyboard without triggering `on_submit`. There is no equivalent on Android — the IME action button handles both submit and dismiss.

---

## Image props (`:image`)

| Prop | iOS | Android | Notes |
|---|---|---|---|
| `src` | `AsyncImage(url:)` | Coil `AsyncImage` | URL string; local file paths also accepted |
| `content_mode: "fit"` | `.aspectRatio(contentMode: .fit)` | `ContentScale.Fit` | Default |
| `content_mode: "fill"` | `.aspectRatio(contentMode: .fill)` | `ContentScale.Crop` | Crops to fill |
| `width` | `.frame(width:)` | `Modifier.width()` | Fixed width in pt/dp |
| `height` | `.frame(height:)` | `Modifier.height()` | Fixed height in pt/dp |
| `corner_radius` | `.clipShape(RoundedRectangle(cornerRadius:))` | `RoundedCornerShape` + clip | Applied after dimensions |
| `placeholder_color` | `Color(argb)` shown while loading or on error | Same | Defaults to system gray |

iOS reference: [AsyncImage (SwiftUI)](https://developer.apple.com/documentation/swiftui/asyncimage)
Android reference: [Coil](https://coil-kt.github.io/coil/compose/)

---

## Scroll props (`:scroll`)

| Prop | iOS | Android |
|---|---|---|
| `axis: :vertical` (default) | `ScrollView(.vertical)` | `Modifier.verticalScroll` on a `Column` |
| `axis: :horizontal` | `ScrollView(.horizontal)` | `Modifier.horizontalScroll` on a `Row` |
| `show_indicator: false` | `.scrollIndicators(.hidden)` | `ScrollState` (indicators not natively controllable in Compose) |

Android's `verticalScroll` modifier also applies `.imePadding()` so the keyboard does not obscure text fields inside a scroll view.

---

## Video props (`:video`)

| Prop | iOS | Android |
|---|---|---|
| `src` | `AVPlayer(url:)` | ExoPlayer (requires setup — see below) |
| `autoplay` | `player.play()` on appear | Same |
| `loop` | `AVPlayerLooper` | `Player.REPEAT_MODE_ONE` |
| `controls` | `AVPlayerViewController.showsPlaybackControls` | `PlayerControlView` |

**Android note:** The Android video player is currently a stub. Full playback requires adding ExoPlayer (now bundled as `androidx.media3:media3-exoplayer`) to `android/app/build.gradle`:

```groovy
implementation "androidx.media3:media3-exoplayer:1.3.1"
implementation "androidx.media3:media3-ui:1.3.1"
```

iOS reference: [AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)
Android reference: [Media3 ExoPlayer](https://developer.android.com/media/media3/exoplayer)

---

## Tab bar props (`:tab_bar`)

| Prop | iOS | Android |
|---|---|---|
| `tabs` | `TabView` with `.tabItem { Label(...) }` | `Scaffold` + `NavigationBar` + `NavigationBarItem` |
| `active` | `TabView(selection:)` binding | `selectedItem` state |
| `on_tab_select` | `Binding.set` calls NIF | `onClick` calls NIF |
| Tab `icon` | SF Symbol name (string) | Material icon name resolved via string lookup |

iOS tab icons are SF Symbols — pass the symbol name as a string (e.g. `"house"`, `"person.fill"`). See [SF Symbols](https://developer.apple.com/sf-symbols/).

Android tab icons use Material icons. The same SF Symbol names work as a best-effort match; unrecognised names fall back to a circle. See [Material Symbols](https://fonts.google.com/icons).

---

## Platform-specific overrides

Any prop can be overridden per-platform using nested `:ios` and `:android` keys:

```elixir
props: %{
  padding:    12,
  ios:        %{padding: 20},       # iOS sees 20; Android sees 12
  android:    %{corner_radius: 4},  # Android gets extra radius; iOS doesn't
}
```

The unmatched platform's block is silently dropped before serialisation. Use this sparingly — prefer semantic tokens and let the platform render naturally.

---

## Component defaults

The renderer injects these defaults for missing styling props. Explicit props always win.

| Component | Default props |
|---|---|
| `:button` | `background: :primary`, `text_color: :on_primary`, `padding: :space_md`, `corner_radius: :radius_md`, `text_size: :base`, `font_weight: "medium"`, `fill_width: true`, `text_align: :center` |
| `:text_field` | `background: :surface_raised`, `text_color: :on_surface`, `placeholder_color: :muted`, `border_color: :border`, `padding: :space_sm`, `corner_radius: :radius_sm`, `text_size: :base` |
| `:divider` | `color: :border` |
| `:progress` | `color: :primary` |

All other components have no injected defaults — unstyled components use the platform's own defaults.

---

## Toggle and slider props

### `:toggle`

| Prop | iOS | Android |
|---|---|---|
| `label` | `Toggle(label, isOn:)` — label text | `Text` inside a `Row` beside `Switch` |
| `value` | `isOn` binding initial value | `checked` state |
| `on_change` | `.onChange(of: isOn)` → NIF | `onCheckedChange` → NIF |
| `color` | `.tint(Color)` | `SwitchDefaults.colors(checkedThumbColor:)` |

### `:slider`

| Prop | iOS | Android |
|---|---|---|
| `value` | Initial `Slider` value | `value` state |
| `min` | `in: min...max` range lower bound | `valueRange` lower bound |
| `max` | `in: min...max` range upper bound | `valueRange` upper bound |
| `on_change` | `.onChange(of: value)` → NIF | `onValueChange` → NIF |
| `color` | `.tint(Color)` | `SliderDefaults.colors(thumbColor:, activeTrackColor:)` |

---

## Human Interface Guidelines

For design decisions not covered here, refer to the platform design systems directly:

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Material Design 3](https://m3.material.io/)
