# Screen crashes are redacted at the source, not where they are logged

- Date: 2026-09-30
- Status: accepted
- Tickets: MOB-310
- Related: `2026-09-04-defect-reports-are-a-shipped-feature.md` (sink policy),
  `2026-09-30-native-input-is-an-action.md` (receipts never carry a payload)

## Context

Receipts were built never to carry assigns or input payloads (MOB-155,
MOB-305), but a screen crash wrote the same data to the device log, which in a
release build is logcat or the iOS console: `adb` and attached bug reports read
it. A test with a secret in the assigns and in the event params found it in
every channel:

- `Mob.Router`'s "crashed and is being restarted" line, the "given up on" line,
  the "could not be restarted" line and `start_root/3`'s "failed to start" line
  all printed `inspect(reason)` or `Exception.format/3` of the raw exit reason.
- A `FunctionClauseError`'s top stack frame holds the call's arguments: the
  event, its params and the whole `%Mob.Socket{}`. A raw `:erlang.map_get`
  frame holds the map. A `KeyError`'s *message* embeds the map it searched.
- OTP's gen_server crash report printed `State:` (the socket) and
  `Last message:` (`{:event, name, params}`, or a typed `{:change, tag, value}`).
- `Mob.NativeLogger` writes `inspect(report)` for a report, so on a device the
  raw report went to logcat as well as Elixir's translation of it.
- A component stops with its screen's exit reason, so its report repeated the
  screen's crash, plus its own assigns.
- The `{:error, reason}` from `start_root/3` (which `AGENTS.md` tells apps to
  match with `{:ok, _} =`, turning it into a `MatchError` that prints it again),
  and the exit the caller of `GenServer.call` receives.

## Decision

**Redact at the source.** `Mob.Screen.Server` and `Mob.ComponentServer` wrap
every gen_server callback (`init`, `handle_call`, `handle_cast`, `handle_info`,
`terminate`) in a function-level `catch` that re-raises through
`Mob.CrashReport.reraise/3`: an error becomes `%Mob.CrashReport.Redacted{}`
naming the exception's module, with a stacktrace whose argument lists are
replaced by arities and whose locations keep only file and line; an exit
reason is reduced by `Mob.CrashReport.reason/1`; a throw is re-thrown as is,
because gen_server treats a thrown value as the callback's return value. The
receipt is recorded inside, from the raw exception, before this runs.

A **returned** stop reason is an exit reason too: the wrappers pass each
callback's result through `Mob.CrashReport.result/1`, which reduces the reason
in `{:stop, reason}` (init), `{:stop, reason, state}` and
`{:stop, reason, reply, state}`, and in a thrown one. `terminate/2` reduces
the reason it is given before the app's `terminate/2` sees it, which covers
stops that never passed through a callback here (the owner's EXIT,
`GenServer.stop/3`). A component stops with its screen's `:DOWN` reason, so
this is what keeps a screen's raw reason out of its components' exits.

`format_status/1` on both servers redacts the state (assigns keep their keys),
the last message, the queue, and the formatted `:sys` debug log, for
gen_server's crash report. The router's log lines go through
`Mob.CrashReport.format/1`, which is idempotent, so a reason that did not come
through the wrapper (a screen killed from outside) is still reduced.

**proc_lib's crash report is a second channel** that `format_status/1` never
sees: it reads the dying process's mailbox and dictionary directly. Elixir
drops it unless the app sets `handle_sasl_reports: true`, but an app may. So
the process is scrubbed by construction rather than by a logger filter (a
global filter would be an app-wide policy mob installs out of band):
`terminate/2` empties the mailbox and erases every dictionary key not starting
with `$` after the app's `terminate/2` has run, and `init/1` does the same
before it fails. Messages still queued then die with the process anyway. This
narrows the mailbox channel rather than closing it: a message that lands in
the instant between the scrub and proc_lib's read is still printed.

**Messages are dropped, default-deny**, by `Mob.Agent.Receipt.summarize_error/3`
itself, which builds the redacted exception: exception messages are where app
code interpolates state (`raise "failed for #{inspect(user)}"`), and a log is a
sink. Only the messages the framework writes survive
(`Mob.Screen.UnhandledEventError`, which names the event and the screen).

An exit reason keeps its atoms and nested atom-tagged tuples, so `:no_session`
and `{:shutdown, :closed}` survive. A message keeps less: its atom tag and the
names the screen's source defines (an `{:event, name, _}`'s name, a native
input's tag), and never a payload, atoms included, since a toggle's `true` or
a picker's atom is user data: `{:change, :consent, true}` logs as
`{:change, :consent, :redacted}`.

**What this does not close.** A `GenServer.call` exit is
`{reason, {GenServer, :call, [pid, request, timeout]}}`, built on the caller's
side: the wrapper redacts `reason`, but the request (an event's params) stays
raw. Today the only caller of a screen's `{:event, ...}` call,
`Mob.Router.safe_call/1`, discards the exit; a new caller that logs or crashes
on it would print the params.

`:sys.get_status/1` returns the process dictionary and the raw `:sys` debug
ring (when someone turned on `:sys.log/2` or `:sys.trace/2`) beside the
formatted part; only the formatted part is redacted. That is a live
introspection call by someone with node access, who can as easily call
`:sys.get_state/1` or `Mob.Screen.get_socket/1` and read every assign, so it
is not treated as a log.

## Alternatives rejected

- **`format_status/1` alone.** It cannot reach the stacktrace: gen_server hands
  it the bare reason and appends the raw stacktrace to the result afterwards,
  so the `FunctionClauseError` arguments still printed. Verified by test.
- **Redacting only in the router.** Leaves the crash report, the caller's exit
  and the start error.
- **A logger filter rewriting reports.** Global, installed out of band, and
  blind to the exit reason that reaches monitors and callers.
- **Keeping messages in development builds.** Not decided here: a dev build is
  also what testers carry around with real data in it.

## Consequences

- A developer reading a crash sees `KeyError (message withheld …)` and the
  file:line of the raise, not `key :x not found in: %{…}`. The receipt for the
  action records which event it was. This costs real diagnostic detail, as it
  does in receipts, and is the same trade.
- `terminate/2` in a screen or component receives the redacted reason.
- `start_root/3`'s `{:error, reason}` for a raising `mount/3` carries the
  redacted exception.
- A `Task` the app starts is not mob's process: its own crash report still
  prints what it held. Mob's "linked process exited" line is redacted.
