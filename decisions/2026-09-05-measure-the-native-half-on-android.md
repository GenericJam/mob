# Measuring the native half of a frame on Android

Date: 2026-09-05
Status: accepted
Ticket: MOB-146

## Context

`decisions/2026-09-03-measure-the-native-half-of-a-frame.md` established the
iOS side: `Mob.RenderStats` can time the BEAM half of a render but not the
native half, and on a dense screen the native half is most of the cost.
Android had none of it — `native_summary/1` returned `{:error, :unsupported}`
there, which is indistinguishable from "you forgot to enable it".

That made MOB-146 unarguable in the direction it needed to be argued. The
claim is that Android navigation disposes and recreates the composition, the
same defect MOB-129 fixed on iOS. Without a number, a fix for it lands with no
before and no after.

## Decision

### The ring buffer lives in Kotlin, not in the NIF

iOS keeps it in C beside the NIF. On Android the measurement can only be taken
on the main thread, so keeping the buffer next to the writer avoids a JNI hop
per sample on a hot path. `nif_native_stats` fetches the serialised JSON the
way `nif_element_frames` fetches frames, and both Kotlin methods are looked up
with `cacheOptional` so an app generated before they existed still loads.

### The closing bracket rides the frame

This is the part that fails silently with a plausible number, so the rejected
options are worth recording.

`MessageQueue.IdleHandler` is the literal analogue of the
`CFRunLoopObserver(.beforeWaiting)` iOS uses, and it is wrong here. Compose
requests its frame through `Choreographer`, and a vsync callback arrives
asynchronously rather than sitting in the queue. Between the request and the
vsync the queue is genuinely empty, so the handler fires there — before any of
the work being measured — and reports the cost of a field write.

Posting a plain `Runnable` and registering the frame callback from inside it
fails differently and less visibly. `ViewRootImpl.scheduleTraversals` installs
a sync barrier that blocks non-async messages until `doTraversal` runs. With a
traversal already pending, which is the steady state on exactly the busy
screens being measured, that post is held while Compose recomposes at frame V,
so it registers for V+1 and the sample absorbs a whole extra frame. Upward
bias, bimodal, worst under load. Choreographer's own vsync messages are
asynchronous and sail past the barrier, which is why registering directly from
the calling thread does not have the problem.

So the frame callback is registered straight from the NIF thread against a
`Choreographer` captured on the main thread at init. It fires at the start of
the next frame; a message posted from inside it cannot run until the traversal
has measured, laid out and drawn, because that traversal is synchronous.

### Android's `apply_us` is not iOS's `apply_us`

Recorded plainly because a differential test (MOB-157) would otherwise compare
them and conclude something false.

iOS starts its clock on the main thread, after the dispatch hop, with the node
already parsed. Android starts on the NIF thread, after `MobJson.parseNode`
but before the state write, and the interval therefore includes a thread
handoff and up to one vsync of queue latency that iOS's does not.

The parse is deliberately excluded on both. On Android `setRootJson` runs
synchronously from the NIF, so the BEAM-side `set_root_us` already spans the
parse; measuring it here too would double-count it against anyone adding the
two windows.

What this measurement is for is a before-and-after on one platform, taken the
same way on both sides. It is not an absolute native frame cost, and it is not
comparable across platforms.

## Consequences

- First Android navigation baseline, physical moto g power, 1600-node screen:
  `none` p50 266ms, `push` p50 841ms, `pop` p50 916ms. Navigation costs 3.2x a
  re-render of the same tree, which is the gap MOB-146 exists to close.
- The instrument was corroborated before its numbers were believed: in the
  same window the platform logged `Davey! duration=1414ms` and
  `Choreographer: Skipped 67 frames` (~1120ms). The measured figures sit just
  below the platform's, which is the right direction, since the bracket closes
  after the traversal but before GPU swap.
- A burst of `setRootJson` calls arms several brackets that all close on the
  same frame, so each attributes the cost of rendering the last tree to trees
  that were superseded. Over-counting rather than losing samples, and the same
  behaviour iOS has.
- `native_disable/0` keeps the window readable, matching iOS. Clearing on
  disable would empty the buffer the caller is about to read, and the result
  would look exactly like the feature being off.
