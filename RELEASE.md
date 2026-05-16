# Release flow

Canonical release process for the Mob repos (`mob`, `mob_dev`,
`mob_new`). `mob_dev` and `mob_new` reference this file rather than
duplicating it; each adds a short per-repo notes section in its own
CLAUDE.md.

## Trigger model

`mix.exs` is the single source of truth for the version. The `release`
GitHub Actions workflow fires when:

- A push to `master` modifies `mix.exs`
- `workflow_dispatch` is invoked manually (Actions tab → "Run
  workflow")

Any other push to `master` is ignored by the release workflow. Each
step in the workflow (tag, GitHub Release, Hex publish) is
independently idempotent — re-running back-fills only what's missing.

## Version bump rule

**Default: patch (`0.x.y → 0.x.(y+1)`).** Always ask before bumping
any version — never auto-bump as part of a feature commit. Reach for
minor only when:

- A public API broke or was removed
- Several substantive features land in one cut
- A build-system migration or framework architectural shift is
  complete

When unsure, propose patch and confirm with the user. Cheaper to
upgrade after agreement than to downgrade after a commit lands.

## When a bump is warranted

A version bump isn't only for code changes. Cut a patch release any
time the published artifact would meaningfully differ:

- **New functionality** — any added public function, new component
  attribute, new template, new Mix task. Must ship with **tests** that
  exercise the new behaviour and **docs** in the right place
  (module/function `@doc`, guides under `guides/`, or template
  comments for generator changes).
- **Bug fix** affecting behaviour visible to downstream apps.
- **Doc improvements** — module docstring rewrites, guide additions,
  README clarifications. HexDocs is built from the published Hex
  release, so doc-only changes without a bump never reach
  hexdocs.pm. If a contributor improved how the library is documented,
  the bump is what makes that improvement visible.
- **Dependency bump** that downstream consumers should pick up
  (security advisory, transitive runtime fix).

NOT warranted on their own:

- CI workflow tweaks (`.github/workflows/*`)
- Pre-push hook changes (`.githooks/*`)
- Internal test refactors that don't change behaviour
- Worktree cleanup, gitignore edits

When in doubt: if the next person to pull from Hex would benefit from
having this change, bump. If it only affects contributors working in
the repo directly, don't.

## Tests + docs for new functionality

Two non-negotiables for anything that ships:

1. **Tests cover the new behaviour.** A unit test asserting the new
   public API works as advertised. For renderer changes,
   `test/mob/renderer_test.exs` is the canonical pattern; for
   generator-template additions, assert on the rendered output via
   `MobNew.ProjectGeneratorTest`. Tests that exist but don't fail
   when the feature is broken don't count.
2. **Docs land in the right place.** Module-level `@moduledoc` for
   the WHY a module exists, function-level `@doc` for any non-obvious
   public function. Cross-cutting topics belong in `guides/` (e.g.
   `guides/styling.md`, `guides/security.md`). Generator templates
   document inline via comments since they ship verbatim into user
   apps.

The pre-push hook does NOT enforce these — they require human
judgement (a test asserting `1 + 1 == 2` technically exists). But
they're table stakes for any commit that warrants a version bump.

## Step-by-step

### 1. Update `CHANGELOG.md`

Add a new `## [X.Y.Z]` section at the top (below the `---`
separator), with `### Added` / `### Changed` / `### Fixed` /
`### Removed` subsections as needed. The release workflow extracts
this section verbatim into the GitHub Release body, so write it for a
reader who hasn't been in the room.

### 2. Bump `mix.exs`

Edit the `version: "X.Y.Z"` line in the `project/0` keyword list.
Nothing else moves the workflow trigger.

### 3. Run the local preflight

```bash
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
mix test --exclude macos_only --exclude requires_zig
```

These are the same checks `test.yml` runs in CI. Catching them
locally saves a 3-5 min CI round-trip per fix iteration. The
pre-push hook (`.githooks/pre-push`) runs the cheap checks
automatically; the `mix test` step is only required when `mix.exs`
changed in the push (i.e., you're actually cutting a release).

Per-repo extras:

- **`mob_dev`**: also run `mix mob.security_scan` — it's the only
  repo that ships the scanner. The `hex_deps` layer applies to
  mob_dev itself; the gradle / swift / bundled_runtime layers no-op
  (mob_dev has no native surface).
- **`mob_new`**: generator tests need `MOB_DIR=/Users/kevin/code/mob`
  when running from a worktree; the path resolver looks for `mob`
  alongside the project.

### 4. Commit + push

One commit per release. The commit message convention:

```
Bump to X.Y.Z — <one-line description>

<more detail if useful>
```

Push to `master`. The release workflow fires automatically because
`mix.exs` changed.

### 5. Watch the workflow

```bash
gh run watch -R GenericJam/<repo>
```

A successful run does three things in order, each independently
idempotent:

1. Creates and pushes tag `X.Y.Z` (skipped if it already exists)
2. Creates the GitHub Release `X.Y.Z` with the CHANGELOG section as
   body (skipped if it already exists)
3. Publishes to Hex via `mix hex.publish --yes` (skipped if `mix
   hex.info <pkg> <vsn>` already finds the version)

If a step fails partway through (network, transient Hex 503, etc.)
re-run the workflow via `workflow_dispatch` — only the missing steps
will execute.

## Pre-push hook

`.githooks/pre-push` runs the **cheap** preflight on every push:

```
mix format --check-formatted
mix credo --strict
mix compile --warnings-as-errors
```

Sub-10-second total. If `mix.exs` changed in the push, it additionally
runs the full test suite (the "release preflight"). Tests are NOT run
on every push — that's a CI responsibility, and forcing local 30-60s
test runs is what drives people to `--no-verify` (anti-pattern).

**One-time setup** after cloning the repo (or creating a new worktree):

```bash
git config core.hooksPath .githooks
```

git stores this locally per-clone, so each worktree needs it too. To
intentionally bypass on a specific push (rare — be honest about why):

```bash
git push --no-verify
```

## OTP tarball releases (mob_dev only)

The OTP runtime tarballs at `github.com/GenericJam/mob/releases/tag/otp-<hash>`
are a **separate, manual** release flow — not driven by `mix.exs`
version bumps. See `scripts/release/` in `mob_dev` for the build +
publish scripts. The version-bump flow above only ships the Elixir
package; OTP tarball rebuilds are operator steps run when the OTP
source revision or cross-compile flags change.

When you bump `@otp_hash` in `mob_dev/lib/mob_dev/otp_downloader.ex`
to point at a new tarball release, the version bump that ships that
change to Hex still follows the standard flow above.
