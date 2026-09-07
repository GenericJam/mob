# `max_lines` is a native prop, not an Elixir string transform

- Date: 2026-09-07
- Status: accepted

## Context

A `:text` node wrapped without limit on both platforms. The only single-line
text was a `:button` label, hard-coded to one line on each side. An app that
wanted "merchant name on one line, beside an amount that must not shrink" had
no way to say so, and truncated the string by grapheme count in Elixir. That
is a guess: the width available to the text is decided by native layout —
font, dynamic type, `weight`/`fill_width` siblings, screen width — and the
BEAM never sees it.

## Decision

`max_lines: pos_integer()` on `:text`. The renderer forwards it; each platform
caps with its own primitive and ellipsises the tail. Three rules:

- **Unset means unchanged.** iOS keeps `maxLines == 0` as "no limit" and
  applies `.lineLimit` only above zero; Android maps absence to
  `Int.MAX_VALUE` and `TextOverflow.Clip`, which are Compose's own defaults.
  No existing tree renders differently.
- **`nil` is dropped, not sent.** `max_lines: if(compact?, do: 1)` is the
  natural way to write a conditional prop, and a JSON `null` reaches iOS as
  `NSNull` — non-nil, and it does not respond to `integerValue`. The renderer
  drops it so the wire stays clean, and the iOS reader is NSNumber-guarded
  regardless.
- **Anything else raises in the renderer.** It is the one point every
  construction path (map literal, `Mob.UI.text/1`, `~MOB`) passes through, and
  each platform would otherwise coerce a bad value into a different limit
  (Compose rejects `maxLines <= 0` outright).

Truncation is tail-only. iOS also has head and middle modes; Compose `Text`
does not. One mode both can honour beats a prop that means different things
per platform.

## Consequences

- Android's reader lives in the generated `MobBridge.kt` (`mob_new`), so an
  app must be regenerated, or its bridge re-rendered, to pick it up. An older
  bridge ignores the key and wraps as before.
- `:button` stays at a fixed single line; this prop does not reach it.
