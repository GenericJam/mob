# Measure the native half of a frame

**Date:** 2026-09-03
**Issue:** MOB-126 (and the evidence gate on MOB-129 / MOB-130)

## Context

`Mob.RenderStats` was built for MOB-125 so the rendering-performance epic would
stop being a set of guesses. It measures seven stages: the user's `render/1`,
expansion, reconcile, the prepare walk, `register_tap`, `:json.encode` and
`set_root`.

All seven are on the BEAM side of the boundary. `set_root_us` closes when
`nif_set_root` returns, and on iOS `nif_set_root` finishes by calling
`[[MobViewModel shared] setRoot:transition:]`, which dispatches to the main
thread and returns immediately. Everything SwiftUI then does to build the view
tree, lay it out and hand it to Core Animation happens after that measurement
has closed. Compose on Android is the same shape.

So the native half of every frame has been invisible since the harness was
written. That did not matter until MOB-126, whose whole argument is about how
much the native side costs when `.id(currentNavVersion)` discards the view tree
on navigation. MOB-129 (retain one native tree per live screen) is a large
change justified entirely by that cost, and MOB-130 says the wire-format
decision must be made "on evidence only". None of the three can be settled
against a number nobody has.

## Decision

Record main-thread busy time per applied tree, natively, in a ring buffer that
the BEAM can read over dist.

**What is measured is main-thread busy time**, from the instant the new tree is
applied to the view model to the instant the main run loop goes idle again.
That is deliberately the pessimistic reading: anything else queued on the main
thread inside that window is counted too. It is also the honest one, because a
frame is dropped when the main thread is busy, whoever made it busy. A sample
is an upper bound on that frame's native cost, not an attribution, and the docs
say so.

**The closing bracket is a `beforeWaiting` run loop observer.**
`CATransaction.setCompletionBlock` is the obvious alternative and is wrong here:
SwiftUI's update frequently lands in a later transaction than the one open at
assignment time, so the completion fires before the work being measured has
happened and the measurement reads near zero.

**The transition travels with each sample**, and `native_summary/1` groups on
it rather than pooling. A `"none"` sample is a steady-state re-render into an
existing view tree; `"push"`, `"pop"` and `"reset"` each rebuild the tree
because the root takes a new identity. Pooling them gives a p50 that describes
neither, and the size of that gap is precisely the quantity MOB-126 and MOB-129
are arguing about.

**Off by default, and the disabled path is one relaxed atomic load.** The flag
is `_Atomic` rather than lock-guarded so that an app which never measures
anything does not take, on the main thread, on every `set_root`, a lock that a
NIF thread also takes. The timestamps and the observer are downstream of that
check. `Mob.RenderStats` already sets this standard in its own moduledoc, which
accounts for its cost when disabled down to nanoseconds per call.

**Enabling clears the window**, because enabling is the natural "start
measuring here" marker and callers read it that way. The payload carries
`recorded` and `dropped` so a percentile over a 240-sample ring can be read
honestly: `dropped > 0` says the numbers describe the tail of the run, not all
of it.

**It is a separate window from `frames/0`.** The native sample completes
asynchronously, well after the BEAM frame it belongs to has been committed and
recorded. Correlating the two would mean threading an identifier through the
wire, for a number that is only ever read by a human deciding whether an
optimisation is worth building.

## Consequences

`Mob.RenderStats.native_enable/1`, `native_frames/1` and `native_summary/1`
return `{:error, :unsupported}` rather than raising when the platform's native
half has not implemented them. That covers the host, where `:mob_nif` does not
exist at all, and it covers Android until the Compose half lands. A function
exported from `mob_nif.erl` but absent from the native library keeps its Erlang
stub and raises `:nif_not_loaded`; degrading is better than taking down
whatever is reading stats.

**This ships the iOS half only.** The Android equivalent needs the same shape
around `setRootJson` and a Choreographer or `doOnPreDraw` closing bracket, and
it touches `MobBridge.kt.eex`, which MOB-142 is editing in the same window.
Sequencing them avoids a conflict in a template file that has been the site of
two cross-platform divergences already in this epic. Until it lands, Android
reports `:unsupported`, which is accurate rather than silently zero.

## What this does not do

It does not attribute cost within the native half. It cannot say how much of an
apply was SwiftUI body evaluation versus layout versus a synchronous image
decode on the main thread. If that granularity turns out to be needed, the tool
for it is `os_signpost` read through Instruments, which is a different exercise
with a different audience: signposts are for a human with a profiler open, and
this is for an agent on the end of a dist connection.
