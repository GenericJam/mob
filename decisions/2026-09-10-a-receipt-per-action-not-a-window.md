# A receipt per action, not a window in which anything might have happened

Date: 2026-09-10
Status: accepted
Ticket: MOB-155 (epic MOB-149, phase 1)

## Context

An agent driving a Mob app can ask what the assigns are now. It cannot ask
whether *its* action caused them.

The mechanism behind `tap_xy/3` is the clearest case. It records a process-wide
UI-event counter, injects the tap, and polls for 300ms:

```objc
if (!mob_await_ui_event(seq_before, MOB_TAP_SETTLE_MS)) {
    return ... "no_effect";
}
```

That counter belongs to the process, not to the tap. Anything that bumps it
inside the window — a timer, a scroll notification, a second agent on the same
device — is indistinguishable from the tap landing, so the check reports success
for taps that did nothing. It also fails the other way: on 2026-09-04 it returned
`{:error, :no_effect}` for a tap that demonstrably worked.

A window cannot answer a question about causation. Only a correlation id can.

## Decision

Every dispatched event gets an `action_id`, and the screen assembles a
`%Mob.Agent.Receipt{}` around the callback recording which of five stages the
action reached: `:dispatched`, `:handled` (or `:unhandled`),
`:assigns_changed`, `:navigated`, `:frame_changed`, `:committed`.

**The stages are observed, not reported.** Only `:handled` is proved by the
callback itself; every later stage is a comparison the screen makes for itself —
an assigns digest before and after, a tree fingerprint before and after. A
handler cannot claim an effect it did not have, which is the property that makes
a receipt worth more than a return value.

**The first stage an action fails to reach names the owner.** That is the whole
reason for recording stages separately rather than a boolean:

| Stops at | Owner | Reading |
|---|---|---|
| `:unhandled` | `:event_routing` | a stale tag, a renamed event |
| `:handled` | `:app_code` | the handler ran and decided nothing |
| `:assigns_changed` | `:render_function` | `render/1` ignores what changed |
| `:frame_changed` without `:committed` | `:renderer` | a frame built and never handed over |
| `:navigated` | `:none` | this screen does not paint; the destination does |
| `:committed` with `:frame_changed` | `:none` | nothing to answer for |

"The tap did nothing" is a bug report nobody can route. "The handler ran and
changed `:count`, and the tree did not change" points at a `render/1` that never
reads `:count`. This is the attribution MOB-149 wants computable rather than
guessed.

**A navigation is its own verdict.** The first version of this derived
everything from the paint, and `reply_after_callback/2` deliberately does not
paint when the handler asked to navigate — the owner applies the action and the
destination screen paints. So a tap that pushed a whole new screen recorded
`[:dispatched, :handled]` and reported `:inert`, "the handler ran and decided
nothing", filed against `:app_code`. That is the same lie the process-wide
counter tells, inverted, on the commonest successful action in a mobile app. The
receipt now reads the nav action before it is cleared.

**`:no_visible_change` is not an error.** A handler that updates state the
current screen does not render has done what it was asked. Whether that is a bug
is the caller's judgement; a framework that decides it produces false alarms.

## Two things this deliberately does not do

**It does not add `:telemetry` as a dependency.** `mob` has exactly one runtime
dependency, on a framework whose premise is running on a phone. Events go to
`[:mob, :action, :stop]` only when the host application already has `:telemetry`
loaded.

That check is resolved **once, at startup**, and the first version got this
badly wrong by calling `Code.ensure_loaded?/1` per action. A *negative* result is
not cached: it is a `gen_server` call into `:code_server` plus a scan of the code
path, measured at ~12us against ~0.04us for a loaded module. Since `mob` has no
`:telemetry` dependency, absent is the default case — so the write path would
have routed every event in every app through one global mailbox, in a module
whose documentation boasted that no process was involved.

**It does not claim the pixels changed.** `native_commit` is `:unknown` on a
receipt assembled from the BEAM alone. Handing a frame to `Mob.Sender` is not
proof the platform drew it, and the native acknowledgement is not wired. A
receipt says what the BEAM did. Anything stronger would be the same overclaim the
process-wide counter makes, in better clothes — and this record exists because
that overclaim cost a day.

## Consequences

- The write path is one ETS insert, one `:atomics.add_get/3`, and an eviction
  check, with no process involved. `:atomics` rather than `:counters` because
  read-then-add is not atomic, and two screens dispatching concurrently could be
  issued the same sequence number — which breaks ordering and lets eviction
  delete the wrong row. A GenServer here would serialise every event in the app
  through one mailbox, which is the opposite of what a diagnostic should cost.
- Receipts are bounded at 256 — and the first version bounded at 257, because
  eviction kept the boundary row while three documents stated 256. `count/0` and `dropped/0` are exposed so "no
  receipt for that id" can be distinguished from "that id never existed"; a
  diagnostic that silently forgets is a diagnostic that lies.
- **A receipt carries no application state at all**, and getting this right took
  two attempts. The first stored a hash of assigns and the normalised exception,
  and the exception was the leak: `KeyError`, `MatchError` and `BadMapError`
  embed the term that failed, so a `Map.fetch!/2` against assigns put the entire
  assigns map — secrets included — into ETS and into telemetry metadata. That is
  MOB-147's `SecureField` leak, re-created inside the mitigation that cites it,
  reaching a sink unredacted in direct violation of
  `2026-09-04-defect-reports-are-a-shipped-feature.md`.

  A crash is now reduced to `{kind, exception module, top MFA}`. The **message
  is dropped** unless the framework built it — app code writes `raise "failed
  for \#{inspect(user)}"` as a matter of routine, and truncating does not help
  because `KeyError`'s rendered message is itself "key :x not found in: %{...}".
  Default-deny is the only posture the sink policy allows. It costs real
  diagnostic detail and is worth it.

- **The assigns comparison is a term comparison, not a hash.** `!==` answers
  "did assigns change" exactly and short-circuits: 0.01us against 43us for a
  deep `phash2` over a 1000-row list screen's assigns, and the first version did
  that twice per event. It was answering a boolean question the expensive way,
  on the path of every event in the app.
- The receipt for a crashing handler is written on the way out, before the
  exception propagates. `Mob.Router` wraps dispatch in `safe_call/1` and absorbs
  the crash, so from outside, a handler that exploded and a handler that did
  nothing look identical. That is precisely the case a receipt has to cover.
- `catch` yields the raw Erlang reason (`:function_clause`), which cannot say
  *which* function failed to match. `Exception.normalize/3` recovers the module,
  function and arity — without it, every unmatched event was filed as a crash in
  a handler that was never entered.
- **The diagnostic cannot crash what it observes.** The receipt write is
  wrapped: it runs after a successful event, and in the `catch` clause it would
  otherwise be able to replace the handler's exception with its own — destroying
  the report the feature exists to produce. Relatedly, the store initialises its
  `:persistent_term` state *before* creating the table, because the reverse
  order leaves a window where a second process sees the table, skips
  initialisation, and reads a key that does not exist yet.

- **A `render/1` that raises produces no receipt.** The exception escapes from
  the paint, which runs after the callback returned and outside the `try` that
  wraps it, so the textbook `:render_function` defect is the one case with no
  record. Covering it means wrapping the paint, which changes what a render
  crash does to a screen — a bigger decision than this slice.

- Not yet done, and the reason this is phase 1 of five: nothing consumes
  receipts. `tap_xy`'s window is still in place; replacing it needs the native
  half. The vocabulary beyond `[:mob, :action, :stop]` — deploy, code-load,
  frame prepared/dropped, component allocate/release — is not emitted yet.

- **A test module that calls `Mob.Router.start_root/3` leaks two global
  processes, and the failure lands somewhere else entirely.** `start_root/3`
  brings up `Mob.Sender` and `Mob.Listener` under global names.
  `Mob.Listener.handler/1` wraps a tap tag into `{:mob_route, ...}` *only when a
  listener is running* — so leaving one behind changes what the renderer does
  for every file that runs afterwards. The symptom was two `Mob.RendererTest`
  assertions failing 2 runs in 12, in a file with no connection to this work,
  and passing every time in isolation. CI found it before the pre-merge review
  did.

  The teardown stops the router first, then both globals. Two wrong turns on the
  way: adding `stop_if_running(:mob_screen)` made it fail 12 runs out of 12,
  because it killed whichever process held that name at the time rather than the
  one this module started. `reset_transition_test.exs` already carried a comment
  saying leaving Sender and Listener behind "is what produces cross-file
  ordering flakes" — the precedent was there to read.

