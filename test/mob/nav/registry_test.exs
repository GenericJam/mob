defmodule Mob.Nav.RegistryTest do
  use ExUnit.Case, async: false

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defmodule HomeScreen, do: nil
  defmodule ProfileScreen, do: nil
  defmodule SettingsScreen, do: nil

  defmodule TabApp do
    @behaviour Mob.App

    import Mob.App

    def navigation(:ios) do
      tab_bar([
        stack(:home, root: HomeScreen, title: "Home"),
        stack(:profile, root: ProfileScreen, title: "Profile")
      ])
    end

    def navigation(:android) do
      drawer([
        stack(:home, root: HomeScreen, title: "Home"),
        stack(:settings, root: SettingsScreen, title: "Settings")
      ])
    end

    def navigation(_), do: stack(:home, root: HomeScreen)
  end

  defmodule SimpleApp do
    @behaviour Mob.App

    import Mob.App

    def navigation(_platform), do: stack(:home, root: HomeScreen)
  end

  setup do
    # Clean up any leftover registry and ensure a fresh state per test
    case Process.whereis(Mob.Nav.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts the registry and seeds it from the app module" do
      {:ok, pid} = Mob.Nav.Registry.start_link(SimpleApp)
      assert is_pid(pid)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    end
  end

  describe "lookup/1" do
    test "finds a registered screen" do
      {:ok, pid} = Mob.Nav.Registry.start_link(SimpleApp)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:ok, HomeScreen} = Mob.Nav.Registry.lookup(:home)
    end

    test "returns not_found for unknown atom" do
      {:ok, pid} = Mob.Nav.Registry.start_link(SimpleApp)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:error, :not_found} = Mob.Nav.Registry.lookup(:nonexistent)
    end

    test "seeds both platforms from tab_bar app" do
      {:ok, pid} = Mob.Nav.Registry.start_link(TabApp)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:ok, HomeScreen} = Mob.Nav.Registry.lookup(:home)
      assert {:ok, ProfileScreen} = Mob.Nav.Registry.lookup(:profile)
      assert {:ok, SettingsScreen} = Mob.Nav.Registry.lookup(:settings)
    end
  end

  describe "register/2" do
    test "registers a name→module mapping at runtime" do
      {:ok, pid} = Mob.Nav.Registry.start_link(SimpleApp)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok = Mob.Nav.Registry.register(:detail, ProfileScreen)
      assert {:ok, ProfileScreen} = Mob.Nav.Registry.lookup(:detail)
    end

    test "overwrites an existing mapping" do
      {:ok, pid} = Mob.Nav.Registry.start_link(SimpleApp)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok = Mob.Nav.Registry.register(:home, ProfileScreen)
      assert {:ok, ProfileScreen} = Mob.Nav.Registry.lookup(:home)
    end
  end
end
