# Mob plugin security — trust model

This doc covers how Mob handles the supply-chain risk introduced by
the plugin system (`MOB_PLUGINS.md`, `MOB_STYLES.md`). Plugins ship
native code that statically links into the host's process and runs
with the host's permissions. That's powerful — and same-process
trust requires a coherent vetting story.

The model has three layers:

1. **What Mob's build already prevents structurally** (no runtime
   plugin loading, no `dlopen`, two-step opt-in).
2. **What the framework adds explicitly** (capability enforcement,
   manifest signing, audit tooling, source-hash pinning).
3. **What's left to the ecosystem** (a curated allowlist, a concerns
   feed, community vetting).

This is design-stage. Implementation tasks track in
`plugin_extraction_plan.md` Phase 2.

## Threat model — what we're defending against

1. **Malicious plugin author.** Publishes a useful-looking plugin that
   exfiltrates data, mines crypto, or escalates permissions. Same
   threat as a malicious npm package.
2. **Compromised legitimate plugin.** A previously-trusted plugin's
   maintainer credentials or repo gets compromised; a new release
   smuggles in malicious code. The Solar Winds / event-stream model.
3. **Typosquatting.** `mob_blutooth` vs `mob_bluetooth`. User installs
   the wrong one.
4. **Capability creep.** Plugin starts as "color palette helper,"
   later versions add network calls, file system writes, undeclared
   NIFs. The shape of what the plugin does drifts after the user
   trusted it.
5. **Transitive risk.** Plugin A depends on plugin B; B is malicious
   but A's manifest looked fine.

Not in scope: defending against the host app itself being malicious
(that's the OS's problem), or against the user explicitly granting
permissions they shouldn't (that's a UX problem, not a security one).

## Layer 1 — structural protections (already in place)

These come from the framework architecture, not the security layer
proper. They're listed here so the security model knows what it
doesn't have to re-solve.

**No runtime plugin loading.** Mob plugins are merged at compile
time. There is no `Plugin.load(:url)` API. The host's binary is the
sum of declared + activated plugins at build time.

**No `dlopen` of NIFs.** Mob's App Store / Play Store posture
requires statically linked NIFs. Plugin NIFs are physically embedded
in `libpigeon.so` (Android) or the iOS binary. We cannot execute
native code that wasn't compiled into the build. This eliminates a
huge class of post-install supply-chain attacks that JS plugin systems
face.

**Manifest is data, not code.** Plugin manifests are `.exs` files
evaluated by mob_dev at compile time in a constrained context — they
must reduce to a plain map. A plugin cannot use its manifest
evaluation to `Code.eval` arbitrary code into the host's build.

**Two-step opt-in.** `mix deps.get` installs but does not activate.
A silent dependency update cannot change the host's permissions,
gradle deps, or render tree. Activation requires explicit
`config :mob, :plugins, [...]` (or `:styles`). The diff is printed
at compile time so the user sees what merged.

**Permission opt-in.** A plugin's declared permissions (Android
manifest entries, iOS plist keys) are merged only after the user
activates the plugin. Same gate as iOS entitlements.

## Layer 2 — framework-provided vetting

These are the additions the framework should provide to address the
threat model.

### Capability enforcement at compile time

The manifest declares what the plugin contributes (NIFs, permissions,
iOS frameworks, Gradle deps). The compile step should *refuse* to
merge anything not declared.

Concretely:

- A plugin that doesn't declare `:ios.frameworks` containing
  `"CoreBluetooth"` cannot have its native code link against
  `CoreBluetooth` symbols. The linker fails at build time, not at
  runtime.
- A plugin that doesn't declare `:android.permissions` containing
  `"android.permission.INTERNET"` cannot have its Kotlin/C code that
  was discovered to reach for network resources slip through unnoticed.
  The linker / dexer fails.
- A plugin that doesn't declare `:nifs` at all cannot ship a `.c`
  file that gets compiled into `libpigeon.so`. The build only
  compiles sources listed in `:nifs[*].native_dir`.

The principle: **the manifest is the entire contract**. Anything the
plugin's source tries to do that isn't manifest-declared either fails
to link (preferred) or is flagged by `mix mob.audit_plugins`.

### Manifest signing

Each plugin manifest should be cryptographically signed by the
plugin's author. Mob_dev verifies the signature before activating.

The signed envelope covers:

- The manifest's contents (sha256 of the canonical encoding)
- A hash of every file path the manifest references (Swift, Kotlin,
  C, Zig, plist keys, gradle deps)
- The plugin's `name`, `version`, `mob_version`

A plugin's signature is bound to a public key the author registers
once with the mob project. First-install workflow:

```bash
mix mob.trust_plugin mob_bluetooth
```

…prompts the user with the plugin's public-key fingerprint, the
maintainer's mob.dev profile URL (if any), and the manifest's
declared capabilities. User says yes / no. The fingerprint is
recorded in `mob.exs` so subsequent versions of the same plugin are
silently trusted — but a *different key signing the same plugin name*
is flagged as a key rotation event requiring re-confirmation.

This catches threat 2 (compromised maintainer credentials republishing
under same name) — the signing key change is visible. It also catches
threat 4 (capability creep) — the new manifest needs to be re-trusted
when its declared capability set grows.

### Source-hash pinning

`mix.lock` already pins package versions. Extend to pin a sha256 of
the plugin's `priv/native/` tree, so a Hex package republished with
the same version number but altered native code (a Hex registry
compromise, or a malicious overwrite) is detected by mix.

### `mix mob.audit_plugins`

A new task that scans every activated plugin's Elixir + native source
for patterns Mob considers risky:

- **Code-injection vectors:** `Code.eval_string`, `Code.eval_file`,
  `:erlang.binary_to_term/2` with the safe-mode bit clear, dynamic
  module-name construction in `apply/3`.
- **Undeclared FFI access:** any NIF call that doesn't appear in
  the manifest's `:nifs` list, any iOS framework reference outside
  the declared `:ios.frameworks`.
- **Undeclared I/O:** file system access outside the app sandbox,
  network calls when `:permissions` doesn't include `INTERNET`,
  process spawning (`System.cmd`, `Port.open`).
- **Anti-tamper sniffing:** code that checks for sandboxing, debugger
  attachment, or unusual env vars — patterns more common in malware
  than legitimate plugins.

The task produces a report with per-finding severity. Some findings
are advisory (a legitimate plugin might legitimately use `:os.cmd`);
others should block activation by default and require explicit
opt-in. The default ruleset is conservative; the host app can declare
exemptions:

```elixir
# mob.exs
config :mob, :plugin_audit, [
  exemptions: %{
    mob_chat_kit: [:network_calls],  # known to use HTTP for API
    mob_bluetooth: [:undeclared_ffi]  # legitimate Core Bluetooth use
  }
]
```

Exemptions are visible in the build output — no silent allow-listing.

### Vetting status in `mix mob.plugins`

Annotate each installed plugin with its current vetting state:

```
$ mix mob.plugins
mob_bluetooth      0.3.1   activated   signed (key 9a3c…)   audit ✓
mob_chat_kit       1.0.0   activated   signed (key f1e8…)   audit ⚠ exemptions
mob_demo_xyz       0.1.0   installed   unsigned             audit ✗ blocking
```

States:

- **unsigned** — plugin has no signature. Allowed for `path:` deps
  (local dev) but warned for Hex deps. User can choose to trust
  manually.
- **signed** — manifest signature verifies. Key fingerprint shown.
- **trusted** — plugin's key has been explicitly trusted via
  `mix mob.trust_plugin`. Subsequent updates with same key pass
  silently.
- **audit ✓ / ⚠ / ✗** — outcome of `mix mob.audit_plugins`.
  ✗ blocks activation by default.

## Development mode — author your own without fighting the framework

Security that gets in the way of plugin authors is security that
gets globally disabled. The framework provides explicit modes so
iteration on your own (or a forked) plugin is friction-free, and the
production path is loud but never blocked.

### The three modes

```elixir
# mob.exs

# Default — production-grade. All activated plugins must be signed
# and pass the audit. Path deps and git refs require per-plugin
# exemptions below.
config :mob, :plugin_security, :strict

# Permissive — same checks run; findings warn instead of block.
# For evaluating new plugins before committing trust.
config :mob, :plugin_security, :permissive

# Dev — path deps and git refs accepted unsigned. Audit still
# reports but never blocks. Prints a per-build banner so the state
# is never forgotten.
config :mob, :plugin_security, :dev
```

### Per-plugin escape hatches, available in any mode

```elixir
config :mob, :unsafe_plugins, [
  {:my_wip_plugin,         allow: [:unsigned]},
  {:friend_fork_of_thing,  allow: [:unsigned, :git_ref]},
  {:experimental_thing,    allow: [:undeclared_network]}
]
```

Per-plugin is the more honest interface: you list which packages get
which exemptions and why (the inline comment is the "why"). Global
`:dev` is a convenience for the case where everything is local.

`:unsafe_plugins` works in any security mode — it's how you say "yes,
I know this one specific plugin is unsigned, I'm fine with that, here's
why in a comment." Reviewers see the list in code review.

### Git refs

A plugin pulled via `{:plugin_x, git: "github.com/y/z", ref: "..."}`
is treated as unsigned by default. Git refs are accepted in `:dev`
mode without further configuration; in `:strict` / `:permissive` they
need `allow: [:git_ref]` in `:unsafe_plugins`. This catches the
typosquat-by-fork pattern (`yourorg/popular-plugin` vs
`y0urorg/popular-plugin`) — you can still use the fork, you just have
to acknowledge it explicitly.

### Building a release with unverified plugins

This is the core philosophical point. **You can do it.** The framework
cannot tell the difference between "developer shipping their own
hand-written plugin" and "developer shipping an unvetted third-party
plugin." Both are open-source — you're allowed to ship either.

What the framework does instead is **bang gongs loudly**:

1. **A persistent banner on every build** (debug AND release) listing
   every plugin that's unsigned, unaudited, or git-ref'd. The banner
   does not go away until those plugins are signed or removed.

2. **Release builds add a one-time acknowledgement requirement.**
   The first time you build a release with unverified plugins, mob_dev
   prints the banner and refuses to proceed. To proceed, add to
   `mob.exs`:

   ```elixir
   # I have personally reviewed the unverified plugins listed above.
   # They are either my own code, a fork I maintain, or a third-party
   # plugin I've read end-to-end. I accept responsibility for any
   # security implications.
   config :mob, :acknowledge_unsafe_plugins, true
   ```

   That config line lives in committed source. Reviewers see it.
   `mix mob.audit_plugins` calls it out. The acknowledgement doesn't
   make the banner stop — it just unblocks the build.

3. **Acknowledgement is global, not per-plugin.** Adding it means
   "yes, I've reviewed all of these." Re-adding a new unverified
   plugin doesn't auto-extend the acknowledgement; the build refuses
   again until the user re-acknowledges, which forces them to
   re-read the list.

4. **`mix mob.audit_plugins` continues to print findings.** Even
   acknowledged, even in dev mode, the audit task runs and reports.
   The user can read the findings; the framework doesn't suppress
   them.

The framework treats this like a seatbelt. We tell you you should
wear one. We make it really clear when you're not. We don't lock the
ignition.

### Why not a CLI flag?

Because CLI flags vanish after the build. `mix release --i-know-best`
is invisible after the fact — a reviewer reading the repo can't tell
the release was built with reduced trust. Committed config is the
durable record: the codebase itself shows the decision.

### Why not a hard block in prod?

Two reasons:

- **Self-hosted plugins are legitimate.** A developer authoring their
  own plugin to extract a feature out of core has a perfectly valid
  reason to ship a release with an "unsigned" (unpublished) plugin.
  Refusing this is paternalistic.
- **Forks are legitimate.** A developer fixing a bug in a third-party
  plugin and shipping a release from their fork is doing the right
  thing — that's how open source moves forward. Refusing this blocks
  the patch path.

We're trying to be the home of the hackers. Hackers know what they're
doing; they just need to be reminded loudly when they're stepping
outside the well-lit path.

### What the prod-build banner looks like

```
=========================================================================
[mob] Plugin trust report for release build
=========================================================================

  Signed + audited:
    mob_bluetooth       0.3.1   trusted key 9a3c…
    mob_camera          0.2.0   trusted key f1e8…

  Unverified — proceeding because :acknowledge_unsafe_plugins is set:
    my_wip_plugin        path:plugins/my_wip_plugin   (unsigned)
    friend_fork_of_thing git:github.com/x/y#branch    (unsigned, git_ref)

  These plugins ship with the release. Their behavior is your
  responsibility. See MOB_PLUGIN_SECURITY.md for the trust model.

=========================================================================
```

The banner is unavoidable. It appears in every build's output, in CI
logs, in the developer's terminal. Anyone who looks at the build log
sees exactly what shipped and on what trust basis. Loud and visible
is the substitute for restrictive.

## Layer 3 — ecosystem

What the framework can't unilaterally provide; needs community
infrastructure.

### Curated allowlist

The Mob project (or a community maintainer) curates a list of
"mob-vetted" plugins — plugins that have been read, the author known,
the manifest reviewed. Lives at `https://mob.dev/plugins-vetted.json`
(or wherever) and is fetched by `mix mob.doctor` once a week,
cached locally.

`mix mob.plugins` shows the vetted status:

```
mob_bluetooth      0.3.1   activated   signed   audit ✓   vetted (2026-03)
mob_random_xyz     0.1.0   activated   signed   audit ✓   not vetted
```

Not vetted ≠ bad. It just means nobody from the Mob project has
reviewed it. Users decide what threshold matters.

### Concerns feed

A separate feed at `https://mob.dev/plugin-concerns.json` reporting:

- Known CVEs in specific plugin versions
- Maintainer ownership changes
- Plugins removed for malicious behavior
- Recommended upgrade paths

`mix mob.doctor` and `mix mob.audit_plugins` both consult this
feed and surface concerns in their output. Same model as `npm audit`
+ the GitHub advisory database.

### Reputation signals (downstream of curation)

For each plugin, `mix mob.plugins --verbose` can show:

- Hex download count (last 30 days)
- Time since last release
- Number of open issues / mean time to close
- Whether the package's GitHub repo is archived
- Maintainer's other published packages

These don't decide trust on their own — they're context. Pair with
the curated list for the actual call.

## Putting the layers together

A user activating a new plugin walks through:

1. `mix mob.add_plugin mob_bluetooth`
   - Hex resolves + downloads the package.
   - Mob verifies the manifest signature (Layer 2).
   - Mob checks the audit ruleset (Layer 2).
   - Mob checks the curated allowlist (Layer 3).
   - Mob checks the concerns feed (Layer 3).
2. Mob prints a one-screen summary:

   ```
   mob_bluetooth 0.3.1
     Author: alice@example.com (key 9a3c…12ef)
     Capabilities: BLUETOOTH_CONNECT, BLUETOOTH_SCAN, CoreBluetooth
     Audit: ✓ no findings
     Vetted: yes (reviewed 2026-03-12)
     Concerns: none

   Activate? [y/N]
   ```

3. User confirms; mob_dev merges contributions, prints the resulting
   permission diff to `AndroidManifest.xml` and `Info.plist`.

A plugin failing any layer can still be activated — but the user has
to add the per-plugin entry to `:unsafe_plugins` (see the
"Development mode" section above) so the decision is visible in
committed code.

## Phasing the implementation

Per `plugin_extraction_plan.md` Phase 2:

1. **First (blocks Phase 3):** capability enforcement at compile
   time, manifest signing format, `mix mob.audit_plugins` with the
   default ruleset. These are framework-internal and have to be
   stable before real extractions ship.
2. **Second (parallel with Phase 3):** the curated allowlist
   infrastructure, concerns feed, reputation signals. Can iterate.
3. **Third (post-extractions, ongoing):** trust-key rotation policy,
   plugin author guides ("how to publish a vetted plugin"),
   periodic re-audit of vetted plugins.

The order matters because waves of extraction shouldn't happen until
the *signed manifest* format and the *audit ruleset* are stable —
otherwise we're shipping plugins without the chain of custody we want
end users to rely on.

## What we explicitly don't promise

- **Not a sandbox.** Plugins run in-process with full BEAM/native
  access. We can't isolate them at runtime the way browser extensions
  are isolated. The protection is compile-time (no surprises in the
  binary), not runtime.
- **Not a gatekept registry.** Anyone can publish a `mob_*` Hex
  package. The curated allowlist is opt-in trust, not gatekept entry.
- **Not protection against the developer themselves.** Releasing with
  unverified plugins is allowed — it's open source, you're allowed to
  ship your own code. The framework makes the situation visible, not
  impossible. The seatbelt model: we tell you you should wear one,
  we make it really clear when you're not, we don't lock the
  ignition. See "Development mode" above for the mechanics.

The goal is "informed consent at activation time, structural
prevention of post-install drift, persistent visible warnings when
the user steps outside the well-lit path" — not unbreakable
sandboxing, not paternalistic refusal to build.

This framework is meant for hackers. Hackers are smart enough to read
the warnings and decide for themselves.
