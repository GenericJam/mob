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
# Needs a `zig` on PATH (the same toolchain `mix mob.deploy` uses); tagged
# `:zig` and excluded by test_helper.exs when none is found.
defmodule Mob.AndroidLibcFreeTest do
  use ExUnit.Case, async: true

  @moduletag :zig

  @jni_dir Path.expand("../../android/jni", __DIR__)

  @tag :tmp_dir
  test "mob_nif.zig compiles for aarch64 Android without link_libc", %{tmp_dir: tmp} do
    {out, status} =
      System.cmd(
        System.find_executable("zig"),
        [
          "build-obj",
          "-target",
          "aarch64-linux.24.0-android",
          "-fPIC",
          "-OReleaseSmall",
          "-Mroot=" <> Path.join(@jni_dir, "mob_nif.zig"),
          "--cache-dir",
          Path.join(tmp, "zig-cache"),
          "-femit-bin=" <> Path.join(tmp, "mob_nif.o")
        ],
        stderr_to_stdout: true
      )

    assert status == 0, "zig build-obj of mob_nif.zig without libc failed:\n#{out}"
  end
end
