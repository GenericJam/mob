# Source-contract test: mob_nif.zig must be compilable for Android without the
# app-side build.zig setting `link_libc = true`.
#
# The trigger is zig 0.17's rule that `extern "c" fn <libc-name>` in a module
# built without link_libc fails with "dependency on libc must be explicitly
# specified in the build command". MOB-180 (mob #156) added `extern "c" fn
# open/write/close` to write the post_mortem marker; that broke every app
# generated before mob_new 0.5.1 (which now sets `link_libc = true` per
# MOB-196). MOB-226 removed those decls in favour of routing through
# `mob_zig.zig`'s `pub extern fn` bindings, which sidestep the check because
# they omit the `"c"` calling-convention qualifier.
#
# Guards MOB-226. If a future change adds an `extern "c" fn` back to
# mob_nif.zig — for open/write/close or any other libc symbol — this test
# fails so the author sees the tradeoff before an old-style app breaks.
defmodule Mob.AndroidLibcFreeTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  setup_all do
    {:ok, zig: File.read!(Path.join(@root, "android/jni/mob_nif.zig"))}
  end

  test ~s|mob_nif.zig declares no `extern "c" fn` (would require link_libc)|, %{
    zig: zig
  } do
    matches =
      zig
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> String.contains?(line, ~s|extern "c" fn|) end)

    assert matches == [],
           """
           mob_nif.zig contains `extern "c" fn` declarations, which zig 0.17
           refuses to compile without `link_libc` for libc symbols like
           open/write/close/read/malloc. Every app generated before mob_new
           0.5.1 lacks `link_libc = true` in its Android build.zig and will
           break on `mix mob.deploy --native --android`.

           Route the declaration through `mob_zig.zig` as `pub extern fn`
           instead (the `"c"` qualifier is what trips zig's check — a bare
           `extern fn` in an imported module compiles fine, and the runtime
           linkage against Bionic's libc.so is unchanged either way).

           Offending lines:
           #{Enum.map_join(matches, "\n", fn {line, n} -> "  #{n}: #{String.trim(line)}" end)}
           """
  end

  test "the post_mortem marker write path routes through jni.*", %{zig: zig} do
    # The bug's origin (MOB-180) was writeMarker/0 calling open/write/close.
    # Pin the specific replacements so a well-meaning refactor that reaches
    # for `extern "c" fn open` again lights up here, not on a downstream
    # user's Android build.
    assert zig =~ "jni.open("
    assert zig =~ "jni.close("
    assert zig =~ "jni.write("
    assert zig =~ "jni.O_WRONLY"
    assert zig =~ "jni.O_CREAT"
    assert zig =~ "jni.O_TRUNC"
  end
end
