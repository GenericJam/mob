# The differential detector is a pure comparator

Date: 2026-09-10
Status: accepted
Ticket: MOB-157 (epic MOB-149, phase 3)

## Context

Mob's product claim is one design, both platforms. That claim is directly
testable: render the same fixture on iOS and Android, sample each
`Mob.Test.view_tree/1`, compare. The first difference is the framework failing
its own promise.

The MOB-157 unblocker (mob_new #65) landed `MobBridge.uiViewTree()`, so both
platforms now return a normalised map in the same eight-key shape. That closes
the "no data on Android" side; the remaining question is what to do with the
two trees.

## Decision

`Mob.Differential.compare/3` is a **pure Elixir function** over two view-trees.
No devices, no processes, no async work — a function you call with two maps
and get back `:ok` or `{:divergence, %{path, reason, ios, android}}`.

The orchestrator (render the same fixture on two devices and drive
`view_tree/1` on each) is a separate piece of work that belongs to `mob_dev`.
Keeping the comparator pure means:

* Its rules can be tested against known-good and known-bad tree pairs, in the
  suite, in milliseconds.
* Mutating a rule to see whether a test fails without it is cheap. Each rule
  is paired with a test that fails against a specific mutation, verified by
  editing the source and running — the first version of the suite passed
  against `<=` becoming `<` and against the two nil-frame clauses collapsing
  to one, which were fixed here. The
  reversion bar CLAUDE.md sets is the one this feature most needs to meet,
  because the whole point of MOB-157 is that a comparator that *misses* a real
  divergence is worse than none — it launders a bug into a passing check.
* The orchestrator can be built or replaced independently. A comparator whose
  correctness depended on how you sampled the trees would tie the two together
  and make either half harder to change.

## The rules

Four classes of comparison, each guarding a bug class the framework knows how
to catch today, each skipping the classes that would produce false alarms.

**Structure.** Different `type` at a matched position, or different child
counts at any level, is always a divergence. The MOB-147 B-1 shape lives here:
the missing-animation regression showed up as one platform emitting a
transition-container node the other did not. Pinned by a test using that exact
shape.

**Label and value.** Different `label` at the same position is a divergence;
same for `value`. A text prop reaching the tree on one platform and not the
other is exactly the kind of thing a fixture with the same input can catch.

**Frame.** Compared only when *both* sides carry a frame, and with a
tolerance (default 1.0 dp) that absorbs the ordinary rounding difference
between the two layout engines. The both-sides requirement is not a
convenience — Android's `MobBridge.uiViewTree()` populates `frame` only for
nodes with `props["id"]`, so any node without an id has `frame: nil` there and
a real frame on iOS. Reporting that as divergence would flag every non-id'd
node in every fixture, and the report would drown the actual bugs. Fixture
authors give ids to the nodes whose geometry should be compared, and choose
their own coverage.

**Root frame is not compared.** The synthetic root's frame is the screen size.
Comparing an iPad's to a phone's says nothing about the framework, and
flagging it would turn every cross-device run into a divergence.

**Class, bg_color, text_color are not compared yet.** Both are `null` on
Android today — the unblocker documents that colours resolve through the theme
after the tree is built, and a partial answer would misattribute divergence.
When Android surfaces those fields, adding rules for them is a one-line change
per field; the shape does not need to change.

## First divergence wins

Depth-first, left-to-right, short-circuit. A parent's own divergence is
reported before its children's; among children, the leftmost wins.

The alternative — collect every divergence — would send a defect reader past
the actual first defect into a cascade of derived problems. A structural
mismatch three levels up causes label mismatches at every descendant; the
useful report is the mismatch at three levels up.

## Harness failure is not a defect

`compare/3` returns `{:error, :not_ready}` when either side is `nil`,
`{:error, _}` or `:no_window` — the shapes `Mob.Test.view_tree/1` can hand
back when a device is starting up. Reporting that as `{:divergence, ...}`
would file the *harness's* own gap as a framework defect, which is the class of
error MOB-155 and MOB-156 kept surfacing in the review rounds.

## Consequences

- No orchestration lands with this. The comparator is complete, tested with
  reversion bars for every rule, and pins the MOB-147 B-1 case. Getting two
  live trees to feed it belongs with `mob_dev`, in its own change.
- No defect bus wiring. Divergence returns as data; MOB-159 will pipe it to a
  sink when the sink exists. Until then, `Mob.Differential.describe/1` prints
  a one-line summary suitable for a log or a manual triage.
- The `:frame_tolerance_dp` default is 1.0. Ordinary layout rounding on both
  platforms is well under that; if a fixture needs pixel-accurate agreement it
  lowers the tolerance, and a team on a device where the layout engines round
  unusually can raise it. Not tuned against a device; a first-pass value that
  fixture authors can tighten.
- Nothing consumes the comparator yet. It is deliberately safe to land alone:
  a downstream that never calls it pays nothing.
