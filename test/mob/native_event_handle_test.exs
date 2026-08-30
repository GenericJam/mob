# Android event handles cross the Compose/JNI boundary as integers, so host
# tests pin the native source contract while the pure Zig codec covers values.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.NativeEventHandleTest do
  use ExUnit.Case, async: true

  @source_path Path.expand("../../android/jni/mob_nif.zig", __DIR__)
  @source File.read!(@source_path)

  test "Android event handles carry the render generation" do
    assert @source =~ ~s|const tap_handle_codec = @import("tap_handle_codec.zig")|
    assert @source =~ "var tap_active_generation: u32 = 0"
    assert @source =~ "var tap_build_generation: u32 = 0"

    assert @source =~
             "tap_build_generation = tap_handle_codec.nextGeneration(tap_build_generation)"

    assert @source =~ "tap_handle_codec.encode(tap_build_generation, slot_index)"
  end

  test "active table, count, and generation commit under one lock" do
    [_, commit] = String.split(@source, "// Commit the freshly-built tap table:", parts: 2)
    [commit, _] = String.split(commit, "erts.enif_mutex_unlock(tap_mutex);", parts: 2)

    assert commit =~ "tap_active = 1 - tap_active"
    assert commit =~ "tap_active_count = tap_build_count"
    assert commit =~ "tap_active_generation = tap_build_generation"
  end

  test "all active event-table lookups share generation validation" do
    assert @source =~ "fn resolveActiveTapLocked(handle: c_int) ?*TapHandle"

    assert length(Regex.scan(~r/resolveActiveTapLocked\(handle\)/, @source)) == 3,
           "snapTap, mob_set_throttle_config, and throttleCheck must use the shared lookup"

    refute @source =~ "handle >= tap_active_count"
    refute @source =~ "tap_tables[tap_active][@intCast(handle)]"
  end

  test "sender tags are copied before the tap-table lock is released" do
    [_, snap] = String.split(@source, "fn snapTap", parts: 2)
    [snap, _] = String.split(snap, "/// `{:event, tag}`", parts: 2)

    {lock, _} = :binary.match(snap, "erts.enif_mutex_lock(tap_mutex)")
    {copy, _} = :binary.match(snap, "erts.enif_make_copy(env, h.tag)")
    {unlock, _} = :binary.matches(snap, "erts.enif_mutex_unlock(tap_mutex)") |> List.last()

    assert lock < copy and copy < unlock
    assert snap =~ "resolveActiveTapLocked(handle) orelse {"
    assert length(:binary.matches(snap, "erts.enif_mutex_unlock(tap_mutex)")) == 2
  end

  test "every tag snapshot owns and frees its delivery environment" do
    snapshots = Regex.scan(~r/snapTap\(handle, env\)/, @source)

    allocated_snapshots =
      Regex.scan(
        ~r/const env = erts\.enif_alloc_env\(\) orelse return;\s+defer erts\.enif_free_env\(env\);\s+const snap = snapTap\(handle, env\) orelse return;/,
        @source
      )

    assert length(snapshots) == 9
    assert length(allocated_snapshots) == length(snapshots)
  end
end
