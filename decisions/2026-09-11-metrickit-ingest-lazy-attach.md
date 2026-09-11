# MetricKit ingest attaches lazily and drains on demand

- Date: 2026-09-11
- Status: accepted

## Context

MOB-179 adds MetricKit ingest for `Mob.PostMortem.IOS`. The design
question was *when* to attach the `MXMetricManagerSubscriber` and how
the BEAM should learn about delivered payloads.

Three obvious options:

1. **Attach at BEAM boot in `mob_start_beam`.** Payloads land in a
   queue we drain later.
2. **Attach and push directly to a BEAM pid via `enif_send`.** No
   queue on the native side; the caller registers a pid up front.
3. **Attach lazily on the first drain call.** Bounded native queue
   in between, drained on demand.

## Decision

Option 3: lazy attach on the first `Mob.PostMortem.IOS.sweep/0` call,
bounded queue (32 payloads) guarded by an `os_unfair_lock`, drained
by a NIF that copies + clears the queue and returns.

## Consequences

**Why not boot-time attach:** it forces every mob app to pay for
MetricKit's subscriber machinery even if the app never opts into
post-mortem ingest. That violates the discipline the whole
`Mob.PostMortem` subsystem enforces — an app opts in explicitly, and
the framework does no work otherwise. A lazy attach on first drain
gives the same recovery of pending payloads as a boot-time attach
(MetricKit delivers to whichever subscriber is present when it goes
to deliver, and delivery is idle-time-triggered — a subscriber
attached before the next idle window catches everything queued up),
without the always-on cost.

**Why not `enif_send` from the delegate directly:** the caller pid
would need to be registered up front, and outlive every payload the
subscriber ever receives. A screen restart, a router reset, any of a
dozen normal lifecycle events would strand payloads with no live
recipient. The queue-drain pattern makes the recipient a per-call
choice (the process that called `sweep/0`) rather than a
long-standing registration, which matches how `Mob.Defect.Bus`
already works.

**Bounded queue at 32:** a burst of diagnostics on a bad morning
after a bad night. MetricKit itself delivers roughly one payload per
diagnostic class per day, so 32 is generous. On overflow we drop the
oldest — the most recent are the ones a triager wants first, and a
capped ring that discards the newest would silently lose the crash
that just brought the app down.

**The subscriber is a file-scope singleton, not per-instance state.**
An `atomic_flag` guards the attach so two concurrent lazy-init
callers cannot double-register. A test that reloads the module
(unlikely in production, plausible in development) does not clear
the flag or the queue — deliberate, since a hot reload should not
lose queued payloads that arrived between reloads.

**The drain runs on a regular scheduler, not a dirty one.** The
lazy-attach is a fire-and-forget `dispatch_async` to the main queue
(no wait), the queue copy is a bounded critical section under
`os_unfair_lock` (microseconds), and building Elixir terms for
≤32 entries is small work. Nothing here justifies the dirty-scheduler
round trip. `test/mob/nif_scheduling_completeness_test.exs` puts
`post_mortem_ios_drain` in the "returns promptly" list on purpose;
promoting it to dirty-IO would be a defensive posture without a
matching cost.
