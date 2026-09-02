# Native event handles cross the UI/NIF boundary as integers, so host tests pin
# each platform's source contract while the pure Zig codec covers values.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeEventHandleTest do
  use ExUnit.Case, async: true

  @android_source File.read!(Path.expand("../../android/jni/mob_nif.zig", __DIR__))
  @ios_source File.read!(Path.expand("../../ios/mob_nif.m", __DIR__))

  @codec_source File.read!(Path.expand("../../android/jni/tap_handle_codec.zig", __DIR__))

  test "the two handle codecs agree on the bit split" do
    # iOS reimplements the encoding by hand while Android derives it from
    # tap_handle_codec. They are independent implementations of one wire format,
    # and drift between them routes a native event to the wrong process — or to
    # a live slot that belongs to something else. Nothing else pins them
    # together, so this does.
    assert @codec_source =~ "pub const slot_bits: u5 = 12"
    assert @codec_source =~ "pub const slot_count: usize = 1 << slot_bits"

    assert @codec_source =~
             "pub const max_generation: u32 = (1 << (31 - @as(u32, slot_bits))) - 1"

    # 12 slot bits and a 19-bit generation, spelled out literally on the iOS side.
    assert @ios_source =~ "#define MOB_TAP_SLOT_LIMIT 4096"
    assert @ios_source =~ "#define MAX_EVENT_GENERATION 0x7ffffU"
    assert @ios_source =~ "(generation << 12) | (uint32_t)slot"
    assert @ios_source =~ "raw >> 12"
    assert @ios_source =~ "raw & 0xfffU"

    # And Android's ceiling is the codec's, not a second literal.
    assert @android_source =~ "const MAX_TAP_HANDLES: usize = tap_handle_codec.slot_count"
  end

  test "register_tap grows the table before caching a pointer into it" do
    # The tables are realloc-grown, so a pointer taken before the grow is a
    # use-after-realloc. This is the one ordering the growth design depends on
    # and it is invisible at a glance, since both statements read the same
    # global.
    [_, ios_register] =
      String.split(@ios_source, "static ERL_NIF_TERM nif_register_tap", parts: 2)

    [ios_register, _] = String.split(ios_register, "// ── NIF: clear_taps/0", parts: 2)

    {ios_grow, _} = :binary.match(ios_register, "mob_tap_grow_locked(")
    {ios_cache, _} = :binary.match(ios_register, "TapHandle *build = tap_tables[")
    assert ios_grow < ios_cache

    [_, android_register] = String.split(@android_source, "export fn nif_register_tap", parts: 2)
    [android_register, _] = String.split(android_register, "// nif_clear_taps/0", parts: 2)

    {android_grow, _} = :binary.match(android_register, "tapGrowLocked(")
    {android_deref, _} = :binary.match(android_register, "tap_tables[1 - tap_active].?")
    assert android_grow < android_deref
  end

  test "set_root commits no more slots than the tables can hold" do
    # Only clear_taps resets tap_build_count, so a set_root without an
    # intervening clear_taps carries a stale count. When the tables were a fixed
    # 256 that was merely wrong; with two heap allocations of possibly different
    # sizes an unbounded loop reads and then writes past the end of the smaller.
    assert @ios_source =~
             "int committed = tap_build_count < build_cap ? tap_build_count : build_cap"

    assert @ios_source =~ "tap_handle_next = committed;"
    assert @android_source =~ "const committed = if (wanted < build_cap) wanted else build_cap"
    assert @android_source =~ "tap_active_count = @intCast(committed);"

    # And a second set_root commits an empty table rather than re-committing.
    [_, ios_set_root] = String.split(@ios_source, "static ERL_NIF_TERM nif_set_root", parts: 2)
    assert String.contains?(ios_set_root, "tap_build_count = 0;")
  end

  test "Android event handles carry the render generation" do
    assert @android_source =~ ~s|const tap_handle_codec = @import("tap_handle_codec.zig")|
    assert @android_source =~ "var tap_table_generations: [2]u32"
    assert @android_source =~ "var tap_build_generation: u32 = 0"

    assert @android_source =~
             "tap_build_generation = tap_handle_codec.nextGeneration(tap_build_generation)"

    assert @android_source =~ "tap_handle_codec.encode(tap_build_generation, slot_index)"
  end

  test "iOS event handles carry the render generation" do
    assert @ios_source =~ "static uint32_t tap_table_generations[2]"
    assert @ios_source =~ "static uint32_t tap_build_generation = 0"
    assert @ios_source =~ "tap_build_generation = mob_next_handle_generation"
    assert @ios_source =~ "mob_encode_event_handle(tap_build_generation, slot)"
  end

  test "active table, count, and generation commit under one lock" do
    [_, commit] =
      String.split(@android_source, "// Commit the freshly-built tap table:", parts: 2)

    [commit, _] = String.split(commit, "erts.enif_mutex_unlock(tap_mutex);", parts: 2)

    assert commit =~ "tap_active = 1 - tap_active"
    # The count comes from `committed`, not `tap_build_count`: the tables are
    # grown on demand and can differ in size, so the commit is clamped to what
    # the table being published actually holds (MOB-133). The property this test
    # exists for is unchanged — all three land under one lock.
    assert commit =~ "tap_active_count = @intCast(committed)"
    assert commit =~ "tap_table_generations[tap_active] = tap_build_generation"
  end

  test "all active event-table lookups share generation validation" do
    assert @android_source =~ "fn resolveActiveTapLocked(handle: c_int) ?*TapHandle"

    assert length(Regex.scan(~r/resolveActiveTapLocked\(handle\)/, @android_source)) >= 3

    refute @android_source =~ "handle >= tap_active_count"
    refute @android_source =~ "tap_tables[tap_active][@intCast(handle)]"
  end

  test "sender tags are copied before the tap-table lock is released" do
    [_, snap] = String.split(@android_source, "fn snapTap", parts: 2)
    [snap, _] = String.split(snap, "fn snapChangeTap", parts: 2)

    {lock, _} = :binary.match(snap, "erts.enif_mutex_lock(tap_mutex)")
    {copy, _} = :binary.match(snap, "copyTap(h, env)")
    {unlock, _} = :binary.matches(snap, "erts.enif_mutex_unlock(tap_mutex)") |> List.last()

    assert lock < copy and copy < unlock
    assert @android_source =~ "erts.enif_make_copy(env, tap.tag)"
    assert snap =~ "resolveActiveTapLocked(handle) orelse {"
    assert length(:binary.matches(snap, "erts.enif_mutex_unlock(tap_mutex)")) == 2
  end

  test "every tag snapshot owns and frees its delivery environment" do
    snapshots = Regex.scan(~r/snapTap\(handle, env\)/, @android_source)

    allocated_snapshots =
      Regex.scan(
        ~r/const env = erts\.enif_alloc_env\(\) orelse return;\s+defer erts\.enif_free_env\(env\);\s+const snap = snapTap\(handle, env\) orelse return;/,
        @android_source
      )

    assert length(snapshots) == 8
    assert length(allocated_snapshots) == length(snapshots)

    assert @android_source =~
             ~r/defer erts\.enif_free_env\(env\);\s+const snap = snapChangeTap\(handle, env\) orelse return;/
  end

  test "identity events tolerate stale handles across unchanged renders" do
    assert @android_source =~ "fn snapChangeTap(handle: c_int, env: ?*erts.ErlNifEnv) ?TapSnap"
    assert @android_source =~ "identity_start_generation: u32"
    assert @android_source =~ "tap_handle_codec.generationWithinIdentity"
    assert @android_source =~ "prior.pid.pid == current.pid.pid"
    assert @android_source =~ "erts.enif_compare(prior.tag, current.tag) == 0"
    assert @ios_source =~ "mob_snap_change_tap"
    assert @ios_source =~ "identity_start_generation"
    assert @ios_source =~ "mob_generation_within_identity"
    assert @ios_source =~ "previous[slot].pid.pid == build[slot].pid.pid"
    assert @ios_source =~ "enif_compare(previous[slot].tag, build[slot].tag) == 0"
  end

  test "building tables are unmatchable until their generation is committed" do
    [_, android_clear] = String.split(@android_source, "export fn nif_clear_taps", parts: 2)
    [android_clear, _] = String.split(android_clear, "return erts.ok(env);", parts: 2)

    assert android_clear =~ "tap_table_generations[1 - tap_active] = 0"

    [_, ios_clear] = String.split(@ios_source, "static ERL_NIF_TERM nif_clear_taps", parts: 2)
    [ios_clear, _] = String.split(ios_clear, "return enif_make_atom(env, \"ok\");", parts: 2)

    assert ios_clear =~ "tap_table_generations[1 - tap_active] = 0"
  end

  test "tap registrations allocate their tag environment before publishing the slot" do
    [_, android_register] = String.split(@android_source, "export fn nif_register_tap", parts: 2)
    [android_register, _] = String.split(android_register, "// nif_clear_taps/0", parts: 2)

    {android_alloc, _} = :binary.match(android_register, "erts.enif_alloc_env()")
    {android_publish, _} = :binary.match(android_register, "tap_build_count += 1")
    assert android_alloc < android_publish

    [_, ios_register] =
      String.split(@ios_source, "static ERL_NIF_TERM nif_register_tap", parts: 2)

    [ios_register, _] = String.split(ios_register, "// ── NIF: clear_taps/0", parts: 2)

    {ios_alloc, _} = :binary.match(ios_register, "enif_alloc_env()")
    {ios_publish, _} = :binary.match(ios_register, "tap_build_count++")
    assert ios_alloc < ios_publish
  end

  test "animation-delayed dismissals use identity-preserving stale handling" do
    [_, android_dismiss] =
      String.split(@android_source, "pub export fn mob_send_dismiss", parts: 2)

    [android_dismiss, _] =
      String.split(android_dismiss, "pub export fn mob_send_change_str", parts: 2)

    assert android_dismiss =~ "sendIdentityEvent(handle, \"dismiss\")"

    [_, ios_dismiss] = String.split(@ios_source, "static void mob_send_dismiss", parts: 2)
    [ios_dismiss, _] = String.split(ios_dismiss, "// IME composition", parts: 2)

    assert ios_dismiss =~ "mob_send_identity_event(handle, \"dismiss\")"
  end

  test "iOS copies every routed tag while holding the registry lock" do
    [_, snap] = String.split(@ios_source, "static int mob_snap_tap", parts: 2)
    [snap, _] = String.split(snap, "static int mob_snap_change_tap", parts: 2)

    {lock, _} = :binary.match(snap, "enif_mutex_lock(tap_mutex)")
    {copy, _} = :binary.match(snap, "enif_make_copy(msg_env, active->tag)")
    {unlock, _} = :binary.matches(snap, "enif_mutex_unlock(tap_mutex)") |> List.last()

    assert lock < copy and copy < unlock
  end

  test "component handles reject callbacks from reused slots on both platforms" do
    assert @android_source =~ "component_generations"
    assert @android_source =~ "decodeComponentHandle"
    assert @ios_source =~ "component_handles[slot].generation"
    assert @ios_source =~ "mob_decode_event_handle(handle, &generation, &slot)"
  end

  test "native handle rejections are visible in debug logs" do
    assert @android_source =~ "rejected stale event handle"
    assert @ios_source =~ "rejected stale event handle"
  end
end
