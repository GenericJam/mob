defmodule Mob.NavTest do
  use ExUnit.Case, async: true

  import Mob.App, only: [stack: 2, tab_bar: 1, drawer: 1]

  alias Mob.Nav

  defmodule HomeScreen, do: nil
  defmodule SettingsScreen, do: nil
  defmodule ProfileScreen, do: nil
  defmodule StrayScreen, do: nil

  defp entry(module), do: {module, Mob.Socket.new(module, platform: :android)}

  defp two_tabs do
    tab_bar([
      stack(:home, root: HomeScreen, title: "Home"),
      stack(:settings, root: SettingsScreen, title: "Settings")
    ])
  end

  describe "new/0" do
    test "is an empty single-stack state" do
      nav = Nav.new()
      assert Nav.history(nav) == []
      assert Nav.active(nav) == nil
      assert Nav.stacks(nav) == []
    end
  end

  describe "from_layout/2" do
    test "nil layout produces the empty state" do
      assert Nav.from_layout(nil, HomeScreen) == Nav.new()
    end

    test "records declared stacks in declaration order" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      assert Nav.stacks(nav) == [:home, :settings]
    end

    test "the stack whose root is the mounted module becomes active" do
      nav = Nav.from_layout(two_tabs(), SettingsScreen)
      assert Nav.active(nav) == :settings
    end

    test "a screen that is no stack's root gets its own orphan stack" do
      # It must belong somewhere or switching away would discard it, but it must
      # not squat a declared stack's slot either.
      nav = Nav.from_layout(two_tabs(), StrayScreen)
      assert Nav.active(nav) == :__mob_root__
      assert Nav.stacks(nav) == [:home, :settings]
    end

    test "an orphan screen does not make a declared root unreachable" do
      # Squatting :home would make this a no-op and strand HomeScreen forever.
      nav = Nav.from_layout(two_tabs(), StrayScreen)
      assert {:mount_root, _nav, HomeScreen} = Nav.switch(nav, :home, entry(StrayScreen))
    end

    test "an orphan screen is still parked, not discarded" do
      orphan = entry(StrayScreen)
      nav = Nav.from_layout(two_tabs(), StrayScreen)
      {:mount_root, nav, _} = Nav.switch(nav, :home, orphan)
      assert nav.parked[:__mob_root__] == %{current: orphan, history: []}
    end

    test "the orphan stack is not a switch target" do
      nav = Nav.from_layout(two_tabs(), StrayScreen)
      {:mount_root, nav, _} = Nav.switch(nav, :home, entry(StrayScreen))
      assert Nav.switch(nav, :__mob_root__, entry(HomeScreen)) == :noop
    end

    test "an unrecognised layout is ignored rather than raising" do
      # navigation/1 is app-supplied and unvalidated, and this runs inside
      # Mob.Screen.init/1 — raising would turn a shape Nav.Registry has always
      # tolerated into a failure to boot.
      assert Nav.from_layout([stack(:home, root: HomeScreen)], HomeScreen) == Nav.new()
      assert Nav.from_layout(:nonsense, HomeScreen) == Nav.new()
      assert Nav.from_layout(%{type: :unknown}, HomeScreen) == Nav.new()
    end

    test "a bare stack declaration yields one stack" do
      nav = Nav.from_layout(stack(:only, root: HomeScreen), HomeScreen)
      assert Nav.stacks(nav) == [:only]
      assert Nav.active(nav) == :only
    end

    test "drawer branches are stacks too" do
      layout = drawer([stack(:a, root: HomeScreen), stack(:b, root: SettingsScreen)])
      assert Nav.stacks(Nav.from_layout(layout, HomeScreen)) == [:a, :b]
    end

    test "starts with an empty history" do
      assert Nav.history(Nav.from_layout(two_tabs(), HomeScreen)) == []
    end
  end

  describe "history/1 and put_history/2" do
    test "round-trips the active stack's history" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      history = [entry(ProfileScreen), entry(HomeScreen)]
      assert nav |> Nav.put_history(history) |> Nav.history() == history
    end

    test "does not disturb the active stack name" do
      nav = Nav.from_layout(two_tabs(), HomeScreen) |> Nav.put_history([entry(ProfileScreen)])
      assert Nav.active(nav) == :home
    end
  end

  describe "drop_parked/2" do
    setup do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      {:mount_root, nav, _} = Nav.switch(nav, :settings, entry(HomeScreen))
      %{nav: nav}
    end

    test "removes a matching entry from a parked stack's history", %{nav: nav} do
      doomed = entry(ProfileScreen)
      nav = %{nav | parked: %{home: %{current: entry(HomeScreen), history: [doomed]}}}

      nav = Nav.drop_parked(nav, &(&1 == doomed))

      assert nav.parked[:home].history == []
      refute nav.parked[:home].current == doomed
    end

    test "promotes the history head when a stack's current is dropped", %{nav: nav} do
      doomed = entry(HomeScreen)
      survivor = entry(ProfileScreen)
      nav = %{nav | parked: %{home: %{current: doomed, history: [survivor]}}}

      nav = Nav.drop_parked(nav, &(&1 == doomed))

      assert nav.parked[:home].current == survivor
      assert nav.parked[:home].history == []
    end

    test "removes the stack entirely when nothing is left" do
      # It must not linger with a dead current — switching to it would restore a
      # corpse. Gone from parked means the next switch mounts its root fresh.
      doomed = entry(HomeScreen)
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      nav = %{nav | active: :settings, parked: %{home: %{current: doomed, history: []}}}

      nav = Nav.drop_parked(nav, &(&1 == doomed))

      refute Map.has_key?(nav.parked, :home)
      assert {:mount_root, _nav, HomeScreen} = Nav.switch(nav, :home, entry(SettingsScreen))
    end

    test "leaves non-matching stacks untouched", %{nav: nav} do
      kept = entry(HomeScreen)
      nav = %{nav | parked: %{home: %{current: kept, history: []}}}

      assert Nav.drop_parked(nav, fn _ -> false end).parked[:home].current == kept
    end
  end

  describe "back_target/1" do
    test "the first declared stack exits" do
      assert Nav.back_target(Nav.from_layout(two_tabs(), HomeScreen)) == :exit
    end

    test "a secondary stack returns to the first" do
      nav = Nav.from_layout(two_tabs(), SettingsScreen)
      assert Nav.back_target(nav) == {:switch, :home}
    end

    test "an orphan screen exits — it is not a tab to back out of" do
      assert Nav.back_target(Nav.from_layout(two_tabs(), StrayScreen)) == :exit
    end

    test "a single-stack app exits" do
      nav = Nav.from_layout(stack(:only, root: HomeScreen), HomeScreen)
      assert Nav.back_target(nav) == :exit
    end

    test "no declared layout exits" do
      assert Nav.back_target(Nav.new()) == :exit
    end
  end

  describe "switch/3" do
    test "first visit asks the caller to mount that stack's root" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      assert {:mount_root, _nav, SettingsScreen} = Nav.switch(nav, :settings, entry(HomeScreen))
    end

    test "first visit makes the target active with an empty history" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      {:mount_root, nav, _root} = Nav.switch(nav, :settings, entry(HomeScreen))
      assert Nav.active(nav) == :settings
      assert Nav.history(nav) == []
    end

    test "switching to the already-active stack is a no-op" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      assert Nav.switch(nav, :home, entry(HomeScreen)) == :noop
    end

    test "switching to an undeclared stack is a no-op" do
      # Mob.Socket.switch_tab/2 accepts any atom; a typo must not strand the
      # app on a stack that does not exist.
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      assert Nav.switch(nav, :nope, entry(HomeScreen)) == :noop
    end

    test "returning to a visited stack restores its screen without re-mounting" do
      home = entry(HomeScreen)
      settings = entry(SettingsScreen)

      nav = Nav.from_layout(two_tabs(), HomeScreen)
      {:mount_root, nav, _} = Nav.switch(nav, :settings, home)
      assert {:switched, _nav, restored} = Nav.switch(nav, :home, settings)
      assert restored == home
    end

    test "an inactive stack keeps its own history across a round trip" do
      home_history = [entry(ProfileScreen)]

      nav =
        two_tabs()
        |> Nav.from_layout(HomeScreen)
        |> Nav.put_history(home_history)

      {:mount_root, nav, _} = Nav.switch(nav, :settings, entry(HomeScreen))
      # The active stack's history is the target's, not the one we parked.
      assert Nav.history(nav) == []

      {:switched, nav, _restored} = Nav.switch(nav, :home, entry(SettingsScreen))
      assert Nav.history(nav) == home_history
    end

    test "each stack's history stays independent" do
      nav = Nav.from_layout(two_tabs(), HomeScreen) |> Nav.put_history([entry(ProfileScreen)])
      {:mount_root, nav, _} = Nav.switch(nav, :settings, entry(HomeScreen))

      settings_history = [entry(SettingsScreen), entry(SettingsScreen)]
      nav = Nav.put_history(nav, settings_history)

      {:switched, nav, _} = Nav.switch(nav, :home, entry(SettingsScreen))
      assert length(Nav.history(nav)) == 1

      {:switched, nav, _} = Nav.switch(nav, :settings, entry(HomeScreen))
      assert Nav.history(nav) == settings_history
    end

    test "the active stack is never left in parked" do
      nav = Nav.from_layout(two_tabs(), HomeScreen)
      {:mount_root, nav, _} = Nav.switch(nav, :settings, entry(HomeScreen))
      refute Map.has_key?(nav.parked, :settings)
      assert Map.has_key?(nav.parked, :home)
    end

    test "with no declared layout there is nothing to switch to" do
      assert Nav.switch(Nav.new(), :home, entry(HomeScreen)) == :noop
    end
  end
end
