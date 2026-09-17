# Plugin-manifest tag discovery in `~MOB`

- Date: 2026-09-15
- Status: accepted

## Context

`Mob.Sigil` validates tag names in `~MOB` markup against a compile-time
whitelist baked from `priv/tags/{ios,android}.txt`. Composite tags an
app registers at boot are invisible to that check and warned as
pass-through. Since mob 0.8 an app can silence such warnings via
`config :mob, :extra_tags`, but a Hex-shipped plugin (a UI kit like the
planned `mob_mishka` — the extraction epic MOB-246) has no plugin-level
escape hatch: every consuming app has to duplicate the plugin's tag
list into its own config, or the plugin has to write into
`deps/mob/priv/tags/*.txt` at install time (the `mishka_chelekom`
hack, obsolete post-0.8 but still shipped there).

Progresses the "app-extendable tags" follow-up from
[`2026-06-11-composite-expansion-pass.md`](2026-06-11-composite-expansion-pass.md)
by moving the extension point one layer further out: from the app's
config to the plugin's manifest.

## Decision

Extend the sigil's whitelist union to include tags declared by
installed plugins via their `priv/mob_plugin.exs` manifest, from two
shapes:

1. A new top-level `:tags` field (flat list, bare value, per-platform
   map — same shapes `:extra_tags` accepts, plus platform maps).
2. The existing `:ui_components[].tag` list from tier-2 native plugins,
   which get whitelist coverage for free (no need to also duplicate
   their tag names into `:tags`).

The reader lives in `Mob.Sigil` as a private helper called from
`resolve_type/2`, alongside `extra_tag?/1`. Compile-time-in-the-macro
read of `Application.loaded_applications/0` + `Application.app_dir/2`,
guarded and cached per compile process via the process dictionary.

A malformed plugin manifest is not fatal to the host compile; it logs
a `Logger.warning` naming the file and reason and contributes no tags.
This is stricter than the previous "silently swallow" draft (caught by
adversarial review) and looser than `Mob.Plugins.read_path/1`'s
"raise a fatal authoring error" for the generated *host* manifest —
one bad plugin should not wedge every other plugin's whitelist
contribution.

## Consequences

- `mob_mishka` (MOB-246 epic) can ship tag whitelist membership as a
  normal Hex package property: `mix mob.new foo && add {:mob_mishka,
  ...}` gives a working sigil for every Mishka tag with no user config
  edit and no `deps/mob/priv/tags/*.txt` mutation.
- Existing tier-2 plugins (`mob_camera` today, and any future one)
  auto-benefit — `ui_components[].tag` was already declared for the
  native renderer; now those tags are whitelist-known too.
- Mix does not track the read, so a plugin manifest edit alone doesn't
  recompile screens that used the sigil — `mix compile --force` is the
  documented escape. Matches the existing `:extra_tags` caveat.
- The `Application.loaded_applications/0` walk pays roughly one
  `stat/1` per loaded dep per compiling source file that names an
  unknown tag. Fine at current scale (~50 deps in the largest known
  host); if this ever gets expensive, mtime-caching via
  `:persistent_term` is the escape without a schema change.

## Alternatives considered

- **mob_dev generates a single aggregated tag file per host** (parallel
  to the tier-3/4 runtime manifest at `priv/mob_plugins.exs`).
  Rejected for now: requires a cross-repo bump of mob_dev before mob
  itself can consume the mechanism, and mob's sigil is the natural
  home for the read since it's the only compile-time consumer.
- **Runtime registration** (`Mob.Composite.register_tag/1` at boot).
  Rejected: the sigil check is compile-time, so runtime registration
  is fundamentally invisible to it and forces every plugin back into
  the `:extra_tags` workaround for consumer-facing sigil warnings.
- **Silently swallow all manifest read errors** (the first draft).
  Rejected after review, because a bad manifest becoming a silent no-op
  is exactly the failure mode `Mob.Plugins.read_path/1` was tightened
  to avoid: someone edits a manifest, breaks it, sees no whitelist
  effect, and has nothing to diagnose from.
