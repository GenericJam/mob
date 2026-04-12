# Mob — Agent Instructions

## Standard debugging workflow

The preferred tool is `mix mob.connect` (from `mob_dev` package):

```bash
cd ~/code/mob_demo
mix mob.connect          # discover all devices, tunnel, restart, connect IEx
mix mob.connect --no-iex # same but print node names instead of starting IEx
mix mob.devices          # list connected devices and their status
```

Node names are platform-specific:
- iOS simulator:    `mob_demo_ios@127.0.0.1`
- Android emulator: `mob_demo_android@127.0.0.1`

### EPMD tunneling

iOS simulator shares the Mac's network stack — the iOS BEAM registers directly in
the Mac's EPMD on port 4369. No forwarding needed.

Android is a separate network namespace. `mob_dev` sets up adb tunnels automatically:

```
adb reverse tcp:4369 tcp:4369   # EPMD: device → Mac (Android BEAM registers in Mac EPMD)
adb forward tcp:9100 tcp:9100   # dist:  Mac → device
```

### Port assignment (handled by mob_dev)

Devices are assigned dist ports by index to avoid conflicts:
- Device 0 (Android): port 9100
- Device 1 (iOS sim): port 9101

iOS dist port is passed via `SIMCTL_CHILD_MOB_DIST_PORT` env var; `mob_beam.m` reads
`MOB_DIST_PORT` at startup. Android dist port is passed as an intent extra (`mob_dist_port`);
**`MainActivity.java` does NOT yet read this — multi-Android support is pending.**

Both iOS and Android end up registered in the same Mac EPMD. `mix mob.connect` sets
up all tunnels automatically.

## Day-to-day development loop

```bash
# Edit Elixir code, then:
mix mob.deploy          # compile + push BEAMs + restart apps
mix mob.connect         # tunnel + wait for nodes + drop into IEx

# In IEx (after mob.connect):
mix compile && nl(MobDemo.CounterScreen)   # hot-push one module without restart
Node.list()                                # verify both devices connected
:rpc.call(:"mob_demo_android@127.0.0.1", MobDemo.CounterScreen, :some_fn, [])
```

### Reading live screen state

```elixir
# Screen pid is logged at app start: "[mob] step 5 => {ok,<0.92.0>}"
pid = :rpc.call(:"mob_demo_android@127.0.0.1", :erlang, :list_to_pid, [~c"<0.92.0>"])
socket = :rpc.call(:"mob_demo_android@127.0.0.1", Mob.Screen, :get_socket, [pid])
socket.assigns   # live assigns
```

### Hot code push

```elixir
# After editing a screen:
mix compile && nl(MobDemo.CounterScreen)
# Returns: {:ok, [{:"mob_demo@127.0.0.1", :loaded, MobDemo.CounterScreen}]}
```

### Android distribution

Android cannot start distribution at BEAM launch (races with hwui thread pool, causes
SIGABRT via FORTIFY `pthread_mutex_lock on destroyed mutex`). Instead, `Mob.Dist.ensure_started/1`
defers `Node.start/2` by 3 seconds after app startup. This is handled in the mob library —
app code just calls `Mob.Dist.ensure_started(node: :"my_app_android@127.0.0.1", cookie: :my_secret)`.

ERTS helper binaries (`erl_child_setup`, `inet_gethost`, `epmd`) cannot be exec'd from the
app data directory (SELinux `app_data_file` blocks `execute_no_trans`). They are packaged in
the APK as `lib*.so` in `jniLibs/arm64-v8a/` (gets `apk_data_file` label, which allows exec).
`mob_beam.c` symlinks `BINDIR/<name>` → `<nativeLibraryDir>/lib<name>.so` before `erl_start`.

## Running tests

```bash
mix test          # from ~/code/mob
```

## Key files

- `lib/mob/screen.ex` — GenServer wrapper, lifecycle callbacks
- `lib/mob/socket.ex` — assigns + internal mob state
- `lib/mob/renderer.ex` — walks component tree, issues NIF calls
- `lib/mob/dist.ex` — platform-aware distribution startup
- `src/mob_nif.erl` — Erlang NIF stub (declares all NIF functions)
- `ios/mob_nif.m` — iOS NIF implementation (SwiftUI bridge)
- `android/jni/mob_nif.c` — Android NIF implementation (JNI bridge)
- `ios/mob_beam.m` — iOS BEAM launcher
- `android/jni/mob_beam.c` — Android BEAM launcher
