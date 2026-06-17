# Mob.Files.pick type filtering

- Date: 2026-06-16
- Status: accepted

## Context

`Mob.Files.pick/2` accepted a `:types` option but the native pickers ignored
it — iOS hardcoded `initForOpeningContentTypes:@[UTTypeData]` and Android
launched SAF with `arrayOf("*/*")`. So a picker always offered every file. This
surfaced as an App Store review rejection for Io (the Livebook-on-mob app): the
reviewer picked a non-`.livemd` file and the app errored trying to open it.

The hard part is a platform asymmetry. iOS `UTType` can be built from a filename
extension and filters strictly even for an unregistered custom type. Android SAF
filters by MIME type only and has no extension filter, so a custom extension with
no registered MIME (`.livemd`) cannot be narrowed at the picker.

## Decision

Honor `:types` with a normalized envelope + result enforcement, all owned by
`Mob.Files`:

- `:types` accepts extensions (`"livemd"` / `".livemd"`), MIME strings
  (anything with a `/`), semantic atoms (`:images`, `:video`, `:audio`, `:pdf`,
  `:text`), explicit `{:extension|:mime|:uti, value}` tuples, and `:any`.
- `normalize_types/1` (public, for testability + a documented wire contract)
  produces a JSON list of `%{"kind","value"}` maps. `:any`/`"*/*"` collapses to
  `[]` (no filter). The envelope is passed to `:mob_nif.files_pick/1` as a
  binary (via `IO.iodata_to_binary/1`, since `:json.encode/1` returns an iolist
  that `enif_inspect_binary` would reject).
- iOS `nif_files_pick` parses the envelope into `[UTType]`
  (`typeWithFilenameExtension:` / `typeWithMIMEType:` / `typeWithIdentifier:` /
  semantic constants), falling back to `UTTypeData` when empty or unresolved.
- `accept/2` + `matches?/2` enforce the filter on the *result* (by `name`
  extension / `mime`), covering the Android gap. `{:uti, _}` specs are treated
  as already-enforced by the iOS picker (not checkable from a result map).

The model: **filter where the OS allows, enforce where it doesn't.**

## Consequences

- iOS strictly limits the picker (the App Store fix). Android picker stays wide
  for custom extensions, but `accept/2` gives apps consistent semantics.
- Backward compatible: the default is `:any` → empty envelope → existing
  "offer everything" behavior.
- **Follow-up (not in this change):** the Android Kotlin side still ignores the
  forwarded `typesJson`. Narrowing the SAF picker by MIME (via `MimeTypeMap`)
  lives in the `mob_new` `MobBridge.kt` / `MainActivity.kt` templates, not core
  mob. Tracked separately; `accept/2` makes it a UX nicety, not a correctness
  requirement.
- Native change → not exercised by Elixir tests. Needs an on-device verify
  (`mix mob.deploy --native`, open the picker, confirm only `.livemd` shows on
  iOS) before relying on it.
