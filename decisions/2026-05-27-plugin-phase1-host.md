# Phase 1 plugin prototypes live in a new `mob_plugin_demo` repo, not `mob_m3_test`

- Date: 2026-05-27
- Status: accepted

## Context
`plugin_extraction_plan.md` kickoff item 6 left the Phase 1 working host open:
`mob_m3_test` (default) vs. a dedicated `mob_plugin_demo` repo. The plan's
default was `mob_m3_test`, with the note that a dedicated repo "decouples
plugin-system iteration from theme work but adds repo overhead."

Inspecting `mob_m3_test` at decision time: it is **not a git repo**, it is
theme-focused, and its `mix.exs` still pins `:mob` to the `material-3` worktree
(`{:mob, path: ".../mob/.claude/worktrees/material-3", override: true}`) — the
same worktree Phase 0 flagged for retirement. Building plugin prototypes there
would couple the plugin epic to in-flight theme work and a soon-to-be-retired
worktree, with no version control on the host itself.

## Decision
Phase 1 prototype plugins (the `plugins/` directory and its `path:` deps) live
in a **new, dedicated `mob_plugin_demo` git repo**, depending on `mob` and
`mob_dev`. `mob_m3_test` is left to theme work.

## Consequences
- Plugin-system iteration is decoupled from theme work and from the retiring
  `material-3` worktree; the host has its own git history.
- One additional repo to maintain — accepted as worth it for a clean,
  versioned, single-purpose host.
- Phase 0's "create `plugins/` dir at the working host" precondition is
  satisfied inside this new repo, not `mob_m3_test`.
- Supersedes the plan's stated default; `plugin_extraction_plan.md` references
  to `mob_m3_test` as the host should be read as `mob_plugin_demo`.
