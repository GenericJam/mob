defmodule Mob.RegistryTest do
  use ExUnit.Case, async: true

  alias Mob.Registry

  setup do
    # Start a fresh registry for each test
    {:ok, pid} = Registry.start_link(name: nil)
    %{registry: pid}
  end

  describe "register/3 and lookup/3" do
    test "registers and looks up a component", %{registry: reg} do
      :ok = Registry.register(reg, :column, android: {:mob_nif, :create_column, []})
      assert {:ok, {:mob_nif, :create_column, []}} = Registry.lookup(reg, :column, :android)
    end

    test "registers multiple platforms for same component", %{registry: reg} do
      :ok = Registry.register(reg, :column,
        android: {:mob_nif, :create_column, []},
        ios:     {:mob_nif, :create_vstack, []}
      )
      assert {:ok, {:mob_nif, :create_column, []}} = Registry.lookup(reg, :column, :android)
      assert {:ok, {:mob_nif, :create_vstack, []}} = Registry.lookup(reg, :column, :ios)
    end

    test "returns error for unknown component", %{registry: reg} do
      assert {:error, :not_found} = Registry.lookup(reg, :unknown, :android)
    end

    test "returns error for unknown platform", %{registry: reg} do
      :ok = Registry.register(reg, :my_widget, android: {:mob_nif, :create_widget, []})
      assert {:error, :not_found} = Registry.lookup(reg, :my_widget, :ios)
    end

    test "re-registering overwrites previous entry", %{registry: reg} do
      :ok = Registry.register(reg, :column, android: {:mob_nif, :create_column, []})
      :ok = Registry.register(reg, :column, android: {:mob_nif, :create_column_v2, []})
      assert {:ok, {:mob_nif, :create_column_v2, []}} = Registry.lookup(reg, :column, :android)
    end
  end

  describe "default registry" do
    setup do
      # Start the named registry if not already running
      case Registry.start_link(name: Registry) do
        {:ok, pid} -> on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
        {:error, {:already_started, _}} -> :ok
      end
      :ok
    end

    test "default registry has built-in components registered" do
      assert {:ok, _} = Registry.lookup(Registry, :column, :android)
      assert {:ok, _} = Registry.lookup(Registry, :row, :android)
      assert {:ok, _} = Registry.lookup(Registry, :text, :android)
      assert {:ok, _} = Registry.lookup(Registry, :button, :android)
      assert {:ok, _} = Registry.lookup(Registry, :scroll, :android)
    end
  end

  describe "all/1" do
    test "lists all registered component names", %{registry: reg} do
      :ok = Registry.register(reg, :column, android: {:mob_nif, :create_column, []})
      :ok = Registry.register(reg, :row, android: {:mob_nif, :create_row, []})
      names = Registry.all(reg)
      assert :column in names
      assert :row in names
    end
  end
end
