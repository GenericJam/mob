# Native Extensions

Mob apps can be extended with native code in four ways, accessed
through two Mix tasks. This guide is a summary — the detailed
contract per backend (how Cargo / Zigler / Pythonx normally work,
what Mob changes for static linking, where the bundled Python
runtime comes from on each platform, which workarounds are
transient) lives in
[mob_dev's `guides/nifs.md`](https://hexdocs.pm/mob_dev/nifs.html).
Read that one before debugging a native build.

## Two tasks, one decision

| Question | Use |
|---|---|
| "I want to write a NIF I'll name myself." | `mix mob.add_nif <name>` |
| "I want to enable a pre-named Mob feature." | `mix mob.enable <feature>` |

The split tracks a real distinction. `add_nif` creates *instances*
the user names (`audio_engine`, `image_codec`, `crypto_utils`) and
can have many of. `enable` toggles *singleton features* with fixed
implementations (`pythonx`, `mlx`, `camera`, `notifications`) — each
exists at most once per app.

## `mix mob.add_nif <name>`

Scaffolds a statically-linked NIF: Elixir stub, native skeleton
appropriate to the chosen backend, `:static_nifs` entry in `mob.exs`,
and regenerated dispatch table — one command, one diff.

```bash
mix mob.add_nif audio_engine                    # Elixir-only stub; you wire native side
mix mob.add_nif audio_engine --type c           # also drops c_src/audio_engine.c
mix mob.add_nif audio_engine --type rustler     # native/audio_engine/ Cargo crate + :rustler dep
mix mob.add_nif audio_engine --type zigler      # ~Z sigil in the stub + :zigler dep
mix mob.add_nif audio_engine --type rustler --demo   # also generates a demo screen
```

Why static linking? iOS App Store rejects bundled `.dylib`; Android
`RTLD_LOCAL` hides the parent's `enif_*` symbols from a `dlopen`'d
child. Both platforms force the same answer: link the NIF init
function into the main app binary alongside `libbeam.a`. mob_dev
handles the cross-compile and link automatically — you write the
Rust/Zig/C, run `mix mob.deploy --native`, and the right `.a` ends
up in the right place per arch.

**Bringing in an existing Rust project** (one crate or many — there's
no upper limit) takes four manual steps documented in
[mob_dev's NIF guide](https://hexdocs.pm/mob_dev/nifs.html#bringing-in-an-existing-rust-crate).
You don't need to be a Rust expert to follow it — the steps are
copy-paste.

## `mix mob.enable <feature>`

Toggles an optional feature with a fixed implementation. Patches
`mix.exs`, platform manifests (Info.plist / AndroidManifest.xml),
and any required source files in one Igniter run.

| Feature | What it gives you |
|---|---|
| `liveview` | Phoenix LiveView mode — app renders a local web view |
| `camera` | Camera permission + capture API |
| `photo_library` | Photo picker + saving |
| `file_sharing` | iOS Files-app integration + Android FileProvider |
| `location` | Coarse + fine location permissions and API |
| `notifications` | Push notifications (entitlement + APNs / FCM glue) |
| `pythonx` | Embedded CPython interpreter on iOS + Android |
| `mlx` | Apple MLX tensor math + EMLX Nx backend (iOS) |

```bash
mix mob.enable camera photo_library     # multiple in one command
mix mob.enable pythonx                  # embeds CPython 3.13 on both platforms
mix mob.enable mlx                      # on-device tensor math (iOS, ~30 MB)
```

The `pythonx` and `mlx` features cost real bundle size (~70 MB and
~30 MB respectively). The rest are cheap (manifest entries + a few
hundred lines of generated Elixir/Swift/Kotlin).

For exactly where Mob fetches the bundled CPython runtime from
(BeeWare's `Python-Apple-support` for iOS, Chaquopy for Android, why
two sources, what's identical between them) — see the Pythonx
section of [mob_dev's NIF guide](https://hexdocs.pm/mob_dev/nifs.html#python-via-pythonx).

## What gets generated, where

For any NIF added via `mob.add_nif <name>` (regardless of `--type`):

```
lib/<app>/nifs/<name>.ex                    # Elixir stub module
mob.exs                                     # :static_nifs entry appended
priv/generated/driver_tab_ios.zig           # dispatch table (regenerated)
priv/generated/driver_tab_android.zig       # dispatch table (regenerated)
```

Plus, depending on `--type`:

```
c_src/<name>.c                              # --type c
native/<name>/Cargo.toml                    # --type rustler
native/<name>/src/lib.rs                    # --type rustler
native/<name>/.cargo/config.toml            # --type rustler (macOS link flags)
```

For `mob.enable <feature>` the file list varies per feature — see
the individual feature docs via `mix help mob.enable`.

## Where to dig deeper

| Topic | Location |
|---|---|
| Per-backend mechanics, how each upstream library works, what Mob changes, transient workarounds | [`mob_dev/guides/nifs.md`](https://hexdocs.pm/mob_dev/nifs.html) |
| Embedded CPython app integration (wheels, first-launch extraction, host-dev fallback) | [`mob_dev/guides/python_embedding.md`](https://hexdocs.pm/mob_dev/python_embedding.html) |
| `MobDev.StaticNifs` schema (arch values, per-arch symbol naming) | `MobDev.StaticNifs` module doc |
| Full task references | `mix help mob.add_nif`, `mix help mob.enable` |
