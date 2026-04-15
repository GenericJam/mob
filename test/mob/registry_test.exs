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
      # Use a unique name per test to avoid async collisions
      name = :"Mob.Registry.#{System.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(name: name)
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
      %{default_reg: name}
    end

    test "default registry has built-in components registered", %{default_reg: reg} do
      assert {:ok, _} = Registry.lookup(reg, :column, :android)
      assert {:ok, _} = Registry.lookup(reg, :row, :android)
      assert {:ok, _} = Registry.lookup(reg, :text, :android)
      assert {:ok, _} = Registry.lookup(reg, :button, :android)
      assert {:ok, _} = Registry.lookup(reg, :scroll, :android)
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
