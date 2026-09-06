# Source-contract test: NIF registration flags are a property of the native
# tables, which Elixir cannot execute. Guards MOB-160.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.InputNifSchedulingTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Every one of these blocks a scheduler waiting on the platform UI thread.
  # See decisions/2026-09-05-input-nifs-are-dirty-io.md.
  # `tap_by_label` is deliberately absent: it appears in the capabilities
  # atom list but has no registration entry on either platform.
  @blocking_input_nifs ~w(
    tap tap_xy long_press_xy swipe_xy
    type_text delete_backward clear_text
  )

  # iOS-only, and the asymmetry is real rather than an oversight: iOS's
  # nif_key_press dispatch_syncs to the main queue, while Android's is a
  # hardcoded :not_implemented stub that never touches the UI thread. iOS also
  # blocks in its accessibility lookups — nif_ax_action_at_xy sleeps up to
  # 4 x 50ms retrying — where Android has no AX path at all.
  @ios_only_blocking ~w(key_press ax_action ax_action_at_xy)

  describe "Android" do
    setup do
      %{source: File.read!(Path.join(@root, "android/jni/mob_nif.zig"))}
    end

    test "every blocking input NIF is registered dirty IO-bound", %{source: source} do
      for name <- @blocking_input_nifs do
        entry = registration(source, ~r/\.\{ \.name = "#{name}", .*?\}/s)

        assert entry =~ "ERL_NIF_DIRTY_JOB_IO_BOUND",
               """
               #{name} is registered on a normal scheduler.

               Android's default argv is `-S 1:1` — one normal scheduler — so a
               NIF that waits on the main thread stops every process on the
               device for as long as it waits. A long press holds for its full
               duration by design.

                   #{entry}
               """
      end
    end

    test "the app's own default argv still has exactly one normal scheduler" do
      # If this ever changes, the reasoning above gets weaker, not wrong —
      # but the decision record should be revisited rather than silently drift.
      # Matched loosely: the spacing is `zig fmt` column alignment computed
      # from the longest key in that struct, so renaming a neighbouring flag
      # would otherwise fail this test with a message about scheduler counts
      # that had not changed.
      beam = File.read!(Path.join(@root, "android/jni/mob_beam.zig"))
      assert beam =~ ~r/"-S",\s+"1:1"/
    end

    test "key_press is NOT dirty, because Android's is a stub" do
      # Guards the inverse claim. A dirty scheduler hop to return an atom is
      # pure overhead, and flagging it would make the rule above ("it is dirty
      # because it waits") false of one of its own members.
      source = File.read!(Path.join(@root, "android/jni/mob_nif.zig"))
      entry = registration(source, ~r/\.\{ \.name = "key_press", .*?\}/s)

      assert entry =~ ".flags = 0",
             "Android's nif_key_press returns :not_implemented without touching " <>
               "the UI thread; it has nothing to wait for.\n\n    #{entry}"
    end
  end

  describe "iOS" do
    setup do
      %{source: File.read!(Path.join(@root, "ios/mob_nif.m"))}
    end

    test "every blocking input NIF is registered dirty IO-bound", %{source: source} do
      for name <- @blocking_input_nifs ++ @ios_only_blocking do
        entry = registration(source, ~r/\{"#{name}", \d+, nif_\w+, [^}]*\}/)

        assert entry =~ "ERL_NIF_DIRTY_JOB_IO_BOUND",
               """
               #{name} is registered on a normal scheduler.

               nif_long_press_xy sleeps for the caller's full duration via
               [NSThread sleepForTimeInterval:], and the rest dispatch_sync to
               the main queue.

                   #{entry}
               """
      end
    end
  end

  # Matches the registration entry, not merely the name: the name also appears
  # in the capabilities list and in doc comments, and asserting against those
  # would pass no matter what the flags said.
  defp registration(source, regex) do
    case Regex.run(regex, source) do
      [entry] -> entry
      nil -> flunk("no NIF registration entry matched #{inspect(regex.source)}")
    end
  end
end
