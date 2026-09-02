# Measuring the render pipeline before changing it

- Date: 2026-09-01
- Status: accepted
- Implements: MOB-125, first step of MOB-124
- Builds on: `2026-08-28-sender-serialises-render.md`

## Context

MOB-124 proposed four fixes for rendering performance — retained native trees,
stable identity, lazy scroll containers, and LiveView-style wire patching. They
attack four different stages, and the pipeline had never been measured on a
device. Picking between them on intuition is how weeks go into the wrong one.

## Decision

`Mob.RenderStats` records per-frame stage timings, readable over dist. It is off
by default behind a `:persistent_term` flag, stores into a bounded ETS ring
owned by a GenServer, and reports p50/p95/max with the sample size `n` — not a
mean, because frame cost is not normally distributed and the tail is what a user
feels as stutter.

Three things about its design were not obvious and were each got wrong first.

**A frame spans two processes.** `Mob.Screen.Server.paint/4` runs `render/1`,
expansion and reconcile in the screen process, then casts to `Mob.Sender`, which
runs prepare, encode and `set_root`. Timing state in the process dictionary
therefore cannot span a frame. The screen hands its partial frame to the sender
with `hand_off/1`, and the sender resumes it before committing. The frame is
**paired with its tree when the render cast is dequeued**, not looked up again at
flush time: `Mob.Sender.sync/1` is called from the router, a different process,
so a flush can land between a screen's two casts and would otherwise commit tree
N-1 while holding frame N.

**The ETS table needs an owner process.** Creating it inside `enable/0` makes it
owned by whoever called — over `:rpc.call/4` that is a transient process, so the
table dies the instant enabling returns and every later write goes nowhere.

**`taps` comes from the call counter, not a tree walk.** Recounting handle-valued
props on the finished tree cost 120 ns per node — about 90% of the meter's whole
overhead — to reproduce a number `accumulate/2` already had exactly, for free, as
the calls happened. The walk survives behind `verify_taps/1` as an opt-in
cross-check, because the two disagreeing is how a counting bug announces itself.

## What `total_us` is not

It is stamped in the screen process and closed in the sender, so it spans two
casts and the sender's mailbox, and it includes the meter's own cost. On a
physical device it was observed **exceeding an externally measured frame by
several milliseconds** — only possible because it covers time outside the frame.

It must not be compared against a frame budget or used to compare
configurations. For that, sum the stages, or measure from outside: drive one
render and block on `Mob.Sender.sync/1`. That external method is what the epic
now uses for verification, and it is the reason two published sets of numbers
had to be retracted.

## Consequences

The instrument was wrong in nine ways across two adversarial reviews before it
was right, and four of those defects had already produced published conclusions:
percentiles one rank high (`round/1` where nearest-rank wants `ceil/1 - 1`, which
made p95 the single worst frame for any run under 20), `taps` undercounting
12-fold, dropped frames polluting the byte and duration percentiles, and stage
percentiles computed over different populations without saying so.

The lesson worth keeping is that a meter used to rank work needs the same
adversarial treatment as the work — and that every fix needs a test which fails
when that fix alone is reverted. Checking that one at a time caught two "fixes"
that changed nothing.
