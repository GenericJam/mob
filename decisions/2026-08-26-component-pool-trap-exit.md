# Mob.ComponentServer traps exits so terminate/2 actually runs

- Date: 2026-08-26
- Status: accepted

## Context

MOB-100 reported native component handle pool exhaustion crashing the
screen process on real devices after a few screens of navigation. Two
causes were already known from the report: a fixed 64-slot pool and a
slot-0/sentinel conflation that leaked slot 0 forever.

While building a regression test against the actual production stop path
(`Mob.ComponentRegistry.reconcile/2`, which calls
`Process.exit(component_pid, :shutdown)` directly to stop components that
left the tree), the fix uncovered a third, more fundamental bug:
`Mob.ComponentServer` is a plain `GenServer` that never sets
`Process.flag(:trap_exit, true)`. A non-trapping process that receives a
raw exit signal (any reason other than `:normal`, `:kill` is a separate
untrappable case) terminates immediately at the VM level — `terminate/2`
is never invoked. Verified empirically: a plain `use GenServer` with a
custom `terminate/2` never observes the callback fire under
`Process.exit(pid, :shutdown)` from another process, only under
`GenServer.stop/2` or a `{:stop, ...}` return from a callback.

This means `Mob.ComponentServer.terminate/2` — and therefore
`Mob.ComponentServer`'s `nif.deregister_component/1` call — never ran for
*any* component that left a screen's tree via the normal reconcile path,
not just the ones that happened to land on slot 0. Every screen
navigation leaked every component's native handle. The reported "a few
leftover registrations from prior navigation" was this leak, not an
incidental rounding error.

## Decision

`Mob.ComponentServer.init/1` now calls `Process.flag(:trap_exit, true)`.
A new `handle_info({:EXIT, _from, reason}, state)` clause (ordered before
the generic catch-all `handle_info/2`) converts the now-trapped exit
signal into `{:stop, reason, state}`, routing it through GenServer's
normal stop machinery so `terminate/2` runs and the native handle is
correctly released.

This is standard OTP practice for a process that must run cleanup logic
in response to another process telling it to stop via a raw exit signal
— the same reason supervisors require trap_exit on children whose
`:shutdown` value is a timeout rather than `:brutal_kill`.

## Consequences

- `Mob.ComponentServer` is no longer killable by an arbitrary exit
  signal from an unrelated process the way a non-trapping process would
  be — only `Process.exit(pid, :kill)` (or its own `{:stop, ...}`
  returns) can end it now. This is the correct, intended behavior for a
  process that owns a native resource needing cleanup; no code in this
  repo relied on the old kill-any-exit-signal behavior.
- The register/deregister contract (`:mob_nif.register_component/1`
  returning `{:ok, handle} | {:error, :component_slots_exhausted}`
  instead of a bare int or badarg) is a breaking change to that NIF's
  return shape. Grep confirmed the only call site is
  `lib/mob/component_server.ex`; no downstream app code calls the NIF
  directly.
- The MAX_COMPONENT_HANDLES bump (64 → 256, both platforms) buys
  headroom but is still a fixed pool. A screen rendering hundreds of
  list-row native components will eventually hit it again; a growable
  pool or component recycling is tracked as a longer-term follow-up, not
  addressed here.
