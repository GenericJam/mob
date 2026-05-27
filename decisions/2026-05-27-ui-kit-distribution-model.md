# UI kits have two distribution lanes; the plugin epic owns only the dependency lane

- Date: 2026-05-27
- Status: accepted

## Context
Evaluating a third-party UI kit (Mishka Chelekom) surfaced a model mismatch.
Mishka-class kits are **shadcn-style generators**: a dev-only tool
(`mix mishka.ui.gen.component`, built on Igniter) emits component **source the
user owns and edits** into their project. Components are free; the paid tier is
templates + support. The mob plugin system is **dependency-shaped** (Hex dep +
two-step activation in `mob.exs`).

These are different products. Forcing a generator-style kit into the plugin
manifest would misrepresent the tool and the vendor's identity as an author.

## Decision
Recognize two distribution lanes and keep them separate:

- **Plugin (dependency lane)** — Hex dep + two-step activation. For native-backed,
  capability-bearing, or centrally-maintained/versioned components. This is what
  `MOB_PLUGINS.md` specs and is **in scope** for the plugin extraction epic.
- **Generator lane** — `mix mob.gen.component` (Igniter-based), emitting
  owned-source presentational components into the user's project. This is a
  **separate tool** tracked with the Igniter build-migration work, **NOT** part
  of the plugin extraction epic.

The two can coexist: a generator can scaffold owned source *from* a plugin
package. Decide per-vendor which lane fits. For Mishka specifically, the faithful
port is the **generator lane**.

## Consequences
- The plugin epic stays scoped to the dependency lane; `mix mob.gen.component` is
  not added to its checklist.
- Igniter is shared ground (Mishka is built on it; mob's build migration is
  heading there), so the generator lane is not foreign territory when it's picked
  up.
- A potential UI-kit vendor relationship is protected — the port matches the
  tool's real shape rather than bending it to the manifest.
- Follow-up: spec the generator lane (`mix mob.gen.component`) under the Igniter
  build-migration track when it begins; record that as its own decision.
