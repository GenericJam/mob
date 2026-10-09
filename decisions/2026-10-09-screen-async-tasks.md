# Screen async tasks: a reporting runner per task, consumed before handle_info

- Date: 2026-10-09
- Status: accepted

## Context

A user asked for LiveView's `assign_async` / `start_async` / `stream` to put
skeletons on loading screens. MOB-107 proposed `start_async` / `handle_async`
when every screen shared one process and a task's result could land in the wrong
screen. MOB-112 fixed the routing (one process per screen) and MOB-107 was closed
as superseded, which dropped the API half with it.

Doing it by hand was easy to get wrong, and the guides got it wrong: the
`guides/events.md` examples called `Task.async/1` and never handled the reply.
A screen traps exits, so a hand-rolled task also produced `{:EXIT, pid, :normal}`
on success and a "linked process exited" warning on a crash, both forwarded to
`handle_info/2`.

## Decision

`Mob.Socket.start_async/3`, `Mob.Socket.cancel_async/3`, an optional
`handle_async/3` callback, and `Mob.ScreenCase.render_async/2`, shaped like
LiveView's. The protocol lives in `Mob.Screen.Async`, shared by
`Mob.Screen.Server` and `Mob.ScreenCase` so the off-device harness handles the
same messages a device does.

- **Two processes per task.** A *runner* is linked to the screen, traps exits
  and only reports. A *worker*, linked to the runner, runs the function. Every
  way the worker ends reaches the runner as a message and goes to the screen as
  `{:ok, result}` or `{:exit, reason}`: a raise, a throw, an exit, and also an
  exit signal from a process the function linked to (a crashing inner
  `Task.async/1`). A single linked process can't catch that signal; it would
  pass it on to the screen, and under `Mob.ScreenCase`, where the screen is
  the test process and doesn't trap exits, it would kill the test. The first
  version unlinked before re-raising, which covered only a crash inside the
  function itself; review found the signal case.
- **The screen's exit reaches the runner as a message,** for any reason,
  `:normal` included (a `:normal` exit signal doesn't kill a process that
  doesn't trap exits). The runner then kills the worker. So a screen's tasks
  stop with it without a `terminate/2` hook, and even when the screen is killed
  outright, when no `terminate/2` would run.
- **The screen monitors the runner.** Only a runner killed from outside ends
  without reporting; its `:DOWN` reports it as `{:exit, reason}`.
- **All of a task's messages are consumed before `handle_info/2`**: its result,
  its `:DOWN`, and an `:EXIT` from a tracked pid. The check runs on every
  message a screen receives, so it is pattern matches plus a scan of the
  screen's few running tasks.
- **One task per name; the newest wins.** Starting a running name kills the
  older task silently. A message carrying a token no longer stored is dropped,
  so a stale result can never be delivered.
- **Cancel is decided by the caller, not by the task's exit.** `cancel_async/3`
  flushes a result already in the mailbox, posts `{:exit, reason}` itself, and
  moves the entry to a new token. `Process.exit/2` is asynchronous, so a task
  finishing on another scheduler can still send its result after the flush. The
  new token drops that result; without it, review measured 273 in 300,000
  cancels reporting `{:ok, _}`. Reason `:normal` raises, since it would not stop
  the task. A `start_async/3` that replaces the name before the `{:exit, _}` is
  delivered drops it, like any replacement.
- **`Mob.ScreenCase.render_async/2` waits only for its own view's tasks.** Every
  view in a test reports to the test process, so it matches by token. Without
  that, awaiting one view consumed and dropped another view's results.
- **`handle_async/3` has no default.** `start_async/3` raises when the screen
  doesn't define it. A default no-op would bring back the silently dropped
  result MOB-107 complained about.

## Alternatives rejected

- **`stream` / incremental tree patching.** LiveView needs `stream` because rows
  cross the network. A screen and its native view share a device, and
  `<LazyList>` already virtualizes rows natively. Tree patching was tried
  before: it was involved and fixed no measured performance problem.
- **`assign_async` + `AsyncResult`.** It can be built on `start_async` later.
  A `:loading` assign plus `handle_async/3` already covers skeleton loading.
- **`Task.Supervisor.async_nolink` under an app-level supervisor.** It would
  leave tasks running after their screen stops, and add a supervisor every app
  would have to start.

## Consequences

- A task's crash is still logged by `Task` as a crash report, with the task's
  function. That is the app's own report, as with any `Task`.
- Work that must outlive its screen does not belong in `start_async/3`; it needs
  a process of its own.
- Each task costs two processes instead of one. A screen runs a handful of
  tasks at a time, so the extra process doesn't matter. A result is copied
  twice, worker to runner to screen. Sending it straight from the worker would
  put the result and the runner's `:DOWN` in different senders' order, which
  the BEAM does not guarantee, so the protocol would need more states. Not
  worth it until a profile shows the copy.
