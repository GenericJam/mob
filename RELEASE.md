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

After writing or substantially editing `@moduledoc` / `@doc` strings,
run `mix docs` locally and open `doc/index.html` to confirm
rendering. Common gotchas: heredoc strings need a blank line before
code fences; ExDoc resolves `Mob.Foo` references but not
`Mob.Foo.bar` without backticks; broken module refs render as `nil`
instead of a link; tables need an empty line above to render.
Local preview catches these before they reach hexdocs.pm.

Publishing to hexdocs.pm is **automatic** — `release.yml`'s
`mix hex.publish --yes` step ships package + docs in one call. There
is no separate "publish docs" step. A correct version bump (and only
that) is what makes new docs visible at hexdocs.pm/<package>/<version>.

The pre-push hook does NOT enforce these — they require human
judgement (a test asserting `1 + 1 == 2` technically exists, an
empty `@doc ""` technically has docs). But they're table stakes for
any commit that warrants a version bump.

## Review gate — on by default

**Every release gets a code review of everything that landed since the
last published version, before you publish.** Applies to `mob`,
`mob_dev`, and `mob_new`. Skip it only when the user explicitly says
to — not because the changes look small, not because each PR was
already reviewed on its way in.

This is a *different* gate from the per-commit adversarial review in
`CLAUDE.md`, and neither substitutes for the other. That one asks
whether a change is correct; this one asks whether the accumulated
diff is coherent and safe to ship.

The unit is the **release**, not the PR. What a user pulls from Hex is
the accumulated diff since the last published version, and that diff
is rarely the same shape as any individual PR that went into it.
Per-PR review misses exactly the things that only show up at the seam:
a fix that lands on top of an earlier one and partly undoes it, two
PRs that are each fine but interact badly, and — the one that actually
bit us — work that merges *after* a version bump and therefore isn't
in the release the bump produced.

Scope the review at the diff that's shipping:

```bash
# what a user gets, vs. what's currently published
git diff v<last-published>..HEAD
git log --oneline v<last-published>..HEAD
```

Findings block the release unless they're explicitly accepted; record
an accepted one in `decisions/` rather than leaving it in a review
thread nobody re-reads.

### Version sanity — check before you bump

Two failures this gate exists to catch, both observed:

1. **The version you're about to publish is already published.**
   `mix hex.info <pkg>` shows the latest release. If it already equals
   the version in `mix.exs`, the bump never happened for whatever
   landed since — bump again.
2. **Work merged after the bump commit isn't in that release.** A
   version bump captures the tree at that commit. Anything merged on
   top ships in the *next* release, not the one the bump triggered.
   Confirm with `git log --oneline <bump-commit>..HEAD` that nothing
   you intend to ship is sitting there unreleased.

Cross-repo releases have a third: `mob` and `mob_new` ship in
lockstep for anything spanning a runtime change and its generator
template. Publishing one without the other leaves generated apps
mismatched against the library they depend on.

## Step-by-step

### 1. Review what's shipping

Run the review gate above against `v<last-published>..HEAD`, and the
version-sanity checks. Everything below assumes that came back clean
or with findings explicitly accepted.

### 2. Update `CHANGELOG.md`

Add a new `## [X.Y.Z]` section at the top (below the `---`
separator), with `### Added` / `### Changed` / `### Fixed` /
`### Removed` subsections as needed. The release workflow extracts
this section verbatim into the GitHub Release body, so write it for a
reader who hasn't been in the room.

### 3. Bump `mix.exs`

Edit the `version: "X.Y.Z"` line in the `project/0` keyword list.
Nothing else moves the workflow trigger.

### 4. Run the local preflight

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

### 5. Commit + push

One commit per release. The commit message convention:

```
Bump to X.Y.Z — <one-line description>

<more detail if useful>
```

Push to `master`. The release workflow fires automatically because
`mix.exs` changed.

### 6. Watch the workflow

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
