# iOS text fields draw the node's chrome, with Android's prop semantics

- Date: 2026-10-01
- Status: accepted
- Tickets: MOB-237 (iOS), MOB-197 (Android, mob_new#82)

## Context

iOS `:text_field` used `.textFieldStyle(.roundedBorder)`: a white system field
in the system font on every theme. The renderer's injected `background`,
`text_color`, `placeholder_color` and `border_color` never reached it, and
neither did `font`, `text_size` or `letter_spacing`. Android gained the same
props, plus `disabled`/`enabled`, `max_length`, `lines`, `caret: "end"` and
`caret_color`, in mob_new#82.

## Decision

- **`.plain` style; the node draws the box.** Background, `border_color` /
  `border_width`, `corner_radius` and `padding` are SwiftUI modifiers around the
  field, as for every other node. `plain: true` (no chrome at all) is not part
  of this; the renderer's defaults are the chrome.
- **Same semantics as Android, not a reinterpretation.** The caret follows
  `text_color` unless `caret_color` is set (transparent text hides it).
  `max_length` counts UTF-16 units and rejects only a *lengthening* edit, so a
  value the screen set past the limit can still be deleted. `enabled: false`
  and `disabled: true` both disable, on text fields only. Disabled text is 38%
  of the text colour. `lines > 1` is a multi-line field that tall; return
  inserts a newline.
- **`caret: "end"` uses the UIKit field** (`MobComposingTextField`, already
  used for `on_compose`): SwiftUI exposes no selection before iOS 18 and the
  build targets 17. That field takes the same style props through UIKit
  properties, since SwiftUI modifiers do not reach a wrapped `UITextField`.
  A `UITextField` is single-line, so with `caret: "end"` (or `on_compose`)
  iOS ignores `lines`; Android honours both. The inputs that pin the caret
  (OTP, masks) are single-line, and a `UITextView` variant was not worth it.
- **A single-line `max_length` field also uses the UIKit field.** Rolling the
  SwiftUI binding back in `onChange` is not reliable: on the simulator a max-5
  field typed 123456789 once gave 12345 and once 123458, with the extra
  character on screen. `shouldChangeCharactersIn` rejects before the field
  changes. Multi-line fields keep the SwiftUI rollback (best effort).
- **The UIKit field carries its own Done accessory.** The SwiftUI keyboard
  toolbar does not reach it, and a number pad has no return key.
- **The UIKit field's focus is a plain `@State`, not the `@FocusState`.** A
  `@FocusState` bound to no `.focused` view is reset by SwiftUI on the next
  update; routed through it, the UIKit field resigned the keyboard after every
  keystroke (seen on the simulator: typing "23" left "12" and no keyboard).
  The `on_compose` path had the same wiring before this change.
- **A rejected `max_length` keystroke re-enters `onChange` with the old value
  and may report it again.** That value is one the BEAM already has. A latch to
  suppress it would be order-dependent, which MOB-147 removed from this view.

## Consequences

Theme changes restyle text fields on both platforms. Fields that use the
UIKit field (`caret: "end"`, `on_compose`, single-line `max_length`) have no
SwiftUI-only behaviour such as `.submitLabel`; the UIKit field maps the same
props itself.
