# Guards MOB-226: `android/jni/mob_nif.zig` must compile for Android without
# the app-side build.zig setting `link_libc = true`.
#
# zig 0.17 rejects `extern "c" fn <libc-name>` in a module built without libc
# ("dependency on libc must be explicitly specified in the build command").
# MOB-180 added `extern "c" fn open/write/close` for the post_mortem marker,
# which broke every app generated before mob_new 0.5.1 (MOB-196 added the flag
# to the template only). This test compiles mob_nif.zig exactly the way such an
# app's build.zig does — `build-obj` for an Android target, no `-lc` — so any
# libc dependency reintroduced anywhere in the module fails here, not on a
# user's `mix mob.deploy --native --android`.
#
# It builds for every ABI mob ships (the triples mob_new's build.zig uses), not
# just arm64: mob_zig.zig checks its hand-declared libc structs against the
# target's C layout at comptime, and a struct that is only wrong on 32-bit
# (MOB-523: Timespec as two i64s on armeabi-v7a) fails only the armv7 build.
#
# Needs a `zig` on PATH (the same toolchain `mix mob.deploy` uses); tagged
# `:zig` and excluded by test_helper.exs when none is found.
defmodule Mob.AndroidLibcFreeTest do
  use ExUnit.Case, async: true

  @moduletag :zig

  @jni_dir Path.expand("../../android/jni", __DIR__)

  for {abi, target} <- [
        {"arm64-v8a", "aarch64-linux.24.0-android"},
        {"armeabi-v7a", "arm-linux.24.0-androideabi"},
        {"x86_64", "x86_64-linux.24.0-android"}
      ] do
    @tag :tmp_dir
    test "mob_nif.zig compiles for #{abi} Android without link_libc", %{tmp_dir: tmp} do
      {out, status} =
        System.cmd(
          System.find_executable("zig"),
          [
            "build-obj",
            "-target",
            unquote(target),
            "-fPIC",
            "-OReleaseSmall",
            "-Mroot=" <> Path.join(@jni_dir, "mob_nif.zig"),
            "--cache-dir",
            Path.join(tmp, "zig-cache"),
            "-femit-bin=" <> Path.join(tmp, "mob_nif.o")
          ],
          stderr_to_stdout: true
        )

      assert status == 0, "zig build-obj of mob_nif.zig for #{unquote(abi)} failed:\n#{out}"
    end
  end
end
