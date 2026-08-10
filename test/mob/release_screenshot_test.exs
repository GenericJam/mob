defmodule Mob.ReleaseScreenshotTest do
  use ExUnit.Case, async: true

  # Security invariant, pinned at the source (the native harness can't be exercised on
  # the host — same rationale as Mob.NifDeclarationTest). The iOS test harness is
  # compiled out of release builds (`#if !MOB_RELEASE`) because its synthetic-input NIFs
  # (tap/type/…) use PRIVATE UIKit/IOKit selectors the App Store auto-rejects.
  # `screenshot/3` uses only public APIs (UIGraphicsImageRenderer + drawViewHierarchy),
  # so it is carved into a release-OPT-IN guard (`MOB_ENABLE_SCREENSHOT`) — a host can
  # ship it so an agent can SEE the screen to error-correct in a release build.
  #
  # This test pins the boundary: screenshot MAY be opted into release, but the private
  # synthetic-input NIFs must NEVER be — they stay strictly `#if !MOB_RELEASE`. If a
  # future edit slipped one into the opt-in guard, a release build could ship
  # private-selector code and get the app pulled from the store.
  @objc Path.expand("../../ios/mob_nif.m", __DIR__)

  # NIFs whose iOS implementations synthesize input via private selectors/IOHIDEvent.
  @private_input ~w(tap tap_xy type_text key_press delete_backward clear_text
                    long_press_xy swipe_xy ax_action ax_action_at_xy)

  # Map each `{"name", arity, nif_…}` registration entry to its nearest enclosing
  # `#if` condition, tracking nesting with a stack so it's robust across the file.
  defp registration_guards do
    @objc
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({%{}, []}, fn line, {acc, stack} ->
      cond do
        m = Regex.run(~r/^\s*#\s*if\S*\s+(.*)$/, line) ->
          {acc, [Enum.at(m, 1) | stack]}

        Regex.match?(~r/^\s*#\s*endif/, line) ->
          {acc, Enum.drop(stack, 1)}

        m = Regex.run(~r/^\s*\{"([a-z_0-9]+)",\s*\d+,\s*nif_/, line) ->
          {Map.put(acc, Enum.at(m, 1), List.first(stack) || ""), stack}

        true ->
          {acc, stack}
      end
    end)
    |> elem(0)
  end

  test "screenshot is release-opt-in (guarded by MOB_ENABLE_SCREENSHOT)" do
    guards = registration_guards()
    assert guards["screenshot"], "screenshot NIF not found in the registration table"

    assert guards["screenshot"] =~ "MOB_ENABLE_SCREENSHOT",
           "screenshot must sit behind a MOB_ENABLE_SCREENSHOT opt-in guard; got: #{guards["screenshot"]}"
  end

  test "sample_region stays debug-only — it must not ride the screenshot opt-in" do
    guards = registration_guards()
    assert guards["sample_region"], "sample_region NIF not found in the registration table"

    # sample_region returns raw pixels of an arbitrary rect. Shipped in a release
    # build it would let a caller reconstruct the screen region by region, which
    # is exactly the capability MOB_ENABLE_SCREENSHOT exists to make a conscious
    # opt-in. It is a dev-time colour-verification tool: keep it out of release.
    refute guards["sample_region"] =~ "MOB_ENABLE_SCREENSHOT",
           "sample_region must not be release-opt-in; guard was: #{guards["sample_region"]}"

    assert guards["sample_region"] =~ "!MOB_RELEASE",
           "sample_region must stay behind `#if !MOB_RELEASE`; guard was: #{guards["sample_region"]}"
  end

  test "private synthetic-input NIFs stay strictly debug-only, never release-opt-in" do
    guards = registration_guards()

    for name <- @private_input, guard = guards[name] do
      refute guard =~ "MOB_ENABLE_SCREENSHOT",
             "#{name} uses private selectors and must NOT be release-opt-in; guard was: #{guard}"

      assert guard =~ "!MOB_RELEASE",
             "#{name} must stay behind `#if !MOB_RELEASE`; guard was: #{guard}"
    end
  end
end
