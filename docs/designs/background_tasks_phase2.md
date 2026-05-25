# Background Tasks — Phase 2: Android WorkManager + FCM

## Goal

Cross-platform parity: Android apps receive the same `{:background_task, id, type, payload, deadline_us}` message that iOS delivers via silent push / background fetch. On Android, FCM data messages wake the app and WorkManager runs the background job.

## Design

### Android-native background task lifecycle

1. FCM data message arrives (`content-available` equivalent: `{"mob_background_task": true}` in data payload)
2. `MobFirebaseService.onMessageReceived()` detects the flag and enqueues a `MobBackgroundWorker`
3. `MobBackgroundWorker.doWork()`:
   - Generates UUID
   - Calls JNI `mob_begin_background_task(uuid, type, payload)`
   - Blocks on a `CountDownLatch(1)` until the BEAM calls `complete()` or timeout (25 s)
   - Returns `Result.success()` if BEAM completed, `Result.retry()` if timed out
4. BEAM receives `{:background_task, uuid, :fcm_data, payload_json, deadline_us}`
5. BEAM does work and calls `Mob.Background.Task.complete(uuid, result)`
6. `nif_background_task_complete` on Android counts down the latch
7. Worker returns based on outcome

### Why a latch instead of fire-and-forget?

WorkManager jobs that return immediately (fire-and-forget) don't give the OS accurate feedback about whether the work succeeded. Returning `Result.success()` only after the BEAM confirms completion lets Android schedule future jobs optimally.

### NIF changes

#### `android/jni/mob_nif.zig`

Add:
- `g_bg_tasks: std.HashMap([64]u8, std.Thread.Condition, ...)` — tracks active tasks
- Actually simpler: use `std.Thread.Mutex` + `std.Thread.Condition` per task
- `mob_begin_background_task(uuid_ptr: *const u8)` — called from Kotlin worker via JNI
- `nif_background_task_complete` — looks up task by UUID, signals condition, removes entry

Wait, JNI calls from Kotlin worker → C are straightforward. But NIF calls from BEAM → C happen on a different thread. So we need thread-safe state.

Better: use `erts.enif_mutex` + a simple struct array:

```zig
const BgTask = struct {
    active: bool,
    completed: bool,
    mutex: ?*erts.ErlNifMutex,
};

var g_bg_tasks: [MAX_BG_TASKS]BgTask = ...
```

Actually, simpler than iOS: on Android the worker thread is a Java thread. The NIF runs on a BEAM scheduler thread. We need a condition variable or semaphore to synchronize them.

Zig has `std.Thread.Condition` but we're in a `build-obj` context where `std.Thread` may not link. Better to use POSIX `pthread_cond_t` via `c` import, or avoid blocking entirely.

Alternative design (simpler, no cross-thread synchronization):

1. Worker enqueues, calls JNI to send message to BEAM, returns `Result.success()` immediately
2. BEAM does work asynchronously
3. `nif_background_task_complete` returns `:ok` (no-op)
4. Worker doesn't wait

This is what the current Android `nif_background_task_complete` does. But it loses the "did BEAM finish?" signal.

For v1, let's keep it simple: fire-and-forget with a best-effort check. The BEAM receives the message and does the work. `complete/2` returns `:ok` even though there's nothing to complete.

Actually, looking at the Phase 3 design, I said "Phase 2: Android WorkManager + FCM background" was deferred. The user is now asking for it. But maybe they just want the template-level wiring (MobBackgroundWorker.kt + MobFirebaseService.kt updates) so apps CAN receive FCM background messages, even if `complete/2` is technically a no-op.

Let me implement the minimum viable Phase 2:
1. Add `MobBackgroundWorker.kt` template to mob_new_fork
2. Update `MobFirebaseService.kt` template to enqueue worker for data messages
3. Add WorkManager dependency to build.gradle.eex
4. Add JNI bridge in `android/jni/mob_nif.zig` so worker can send message to BEAM
5. Tests

The critical piece is: the Kotlin worker needs a way to send a message to the BEAM. Looking at the existing code, there's `mob_send_tap`, `mob_send_event`, etc. We need something like `mob_send_background_task(uuid, type, payload)`.

Actually, we can call the existing NIF function from Kotlin via JNI. Or better, call a C function that sends to BEAM just like the iOS `mob_begin_background_task`.

Let me look at how the existing Android C code sends messages to BEAM. There are `mob_send_tap`, `mob_send_change_str`, etc. These are exported from `mob_nif.zig` and called from `beam_jni.c` via JNI.

For background tasks, we need:
1. `mob_begin_background_task(const char* uuid, const char* type, const char* payload_json)` — sends `{:background_task, uuid, type, payload, deadline_us}` to BEAM
2. This needs to work from a Java thread (the WorkManager worker thread)

Looking at the existing `mob_send_tap` implementation, it uses `erts.enif_send`. This requires a valid ErlNifPid and an allocated env. The pid is looked up from the tap registry. For background tasks, we need to send to the device dispatcher pid.

Looking at `g_device_dispatcher_pid` in `mob_nif.zig`:
```zig
var g_device_dispatcher_pid: erts.ErlNifPid = .{ .pid = 0 };
var g_device_dispatcher_set: bool = false;
```

So we can send to `g_device_dispatcher_pid` if it's set. The background task message would be:
```
{:background_task, uuid_string, type_atom, payload_term, deadline_us}
```

Let me implement:
1. `mob_begin_background_task` exported C function in `mob_nif.zig`
2. `MobBackgroundWorker.kt` template
3. `MobFirebaseService.kt` template update

For mob_new_fork, let me check the template files:
- `priv/templates/mob.new/android/app/src/main/java/MobFirebaseService.kt.eex`
- `priv/templates/mob.new/android/app/build.gradle.eex`

Wait, the user's current project is at `~/Projects/mob`. The mob_new_fork is at `~/Projects/mob_new_fork`. Since the user said "Complete │ Phase 2: Android WorkManager + FCM", I should implement across both repos.

But actually, most of the work is in mob (Zig JNI). The templates are in mob_new_fork. I should do both.

Let me create the plan file, then implement.
