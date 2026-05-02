defmodule Mob.Event.TargetTest do
  use ExUnit.Case, async: true
  doctest Mob.Event.Target

  alias Mob.Event.Target

  defp scope(opts \\ []) do
    %{
      screen_pid: Keyword.get(opts, :screen_pid, self()),
      component_chain: Keyword.get(opts, :component_chain, [])
    }
  end

  describe "resolve/2 — :parent" do
    test "resolves to screen when no components in chain" do
      s = scope(screen_pid: self())
      assert Target.resolve(:parent, s) == {:ok, self()}
    end

    test "resolves to innermost component when chain non-empty" do
      outer = spawn_link(fn -> Process.sleep(:infinity) end)
      inner = spawn_link(fn -> Process.sleep(:infinity) end)
      s = scope(component_chain: [{:form, outer}, {:row, inner}])
      assert Target.resolve(:parent, s) == {:ok, inner}
    end
  end

  describe "resolve/2 — :screen" do
    test "always resolves to screen pid, regardless of components" do
      outer = spawn_link(fn -> Process.sleep(:infinity) end)
      s = scope(screen_pid: self(), component_chain: [{:form, outer}])
      assert Target.resolve(:screen, s) == {:ok, self()}
    end
  end

  describe "resolve/2 — {:component, id}" do
    test "resolves to a named ancestor" do
      outer = spawn_link(fn -> Process.sleep(:infinity) end)
      inner = spawn_link(fn -> Process.sleep(:infinity) end)
      s = scope(component_chain: [{:form, outer}, {:row, inner}])

      assert Target.resolve({:component, :form}, s) == {:ok, outer}
      assert Target.resolve({:component, :row}, s) == {:ok, inner}
    end

    test "errors when not in chain" do
      s = scope(component_chain: [{:form, self()}])

      assert Target.resolve({:component, :ghost}, s) ==
               {:error, {:component_not_in_ancestors, :ghost}}
    end

    test "with empty chain, any component lookup fails" do
      s = scope(component_chain: [])

      assert {:error, {:component_not_in_ancestors, :anything}} =
               Target.resolve({:component, :anything}, s)
    end
  end

  describe "resolve/2 — pid" do
    test "alive pid resolves to itself" do
      s = scope()
      assert Target.resolve(self(), s) == {:ok, self()}
    end

    test "dead pid errors" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(pid)
      s = scope()
      assert Target.resolve(pid, s) == {:error, :dead_pid}
    end
  end

  describe "resolve/2 — registered atom" do
    setup do
      name = :"target_test_#{System.unique_integer([:positive])}"
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      Process.register(pid, name)
      {:ok, name: name, pid: pid}
    end

    test "registered name resolves to its pid", %{name: name, pid: pid} do
      s = scope()
      assert Target.resolve(name, s) == {:ok, pid}
    end

    test "unregistered name errors" do
      s = scope()

      assert Target.resolve(:nope_not_registered, s) ==
               {:error, {:not_registered, :nope_not_registered}}
    end
  end

  describe "resolve/2 — {:via, ...}" do
    setup do
      registry = :"reg_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry})

      # Spawn a process that registers itself in the Registry — Registry's
      # register API requires self() == pid being registered.
      parent = self()
      ref = make_ref()

      pid =
        spawn_link(fn ->
          {:ok, _} = Registry.register(registry, "key:1", :ignored)
          send(parent, {ref, :registered})
          Process.sleep(:infinity)
        end)

      assert_receive {^ref, :registered}, 500
      {:ok, registry: registry, pid: pid}
    end

    test "{:via, Registry, key} resolves", %{registry: registry, pid: pid} do
      s = scope()
      assert Target.resolve({:via, Registry, {registry, "key:1"}}, s) == {:ok, pid}
    end

    test "unresolvable via tuple errors", %{registry: registry} do
      s = scope()

      assert {:error, {:via_not_resolvable, Registry, _}} =
               Target.resolve({:via, Registry, {registry, "missing"}}, s)
    end
  end

  describe "resolve/2 — invalid forms" do
    test "binary target errors as :invalid_target" do
      s = scope()

      assert {:error, {:invalid_target, "not a valid target"}} =
               Target.resolve("not a valid target", s)
    end

    test "integer target errors as :invalid_target" do
      s = scope()
      assert {:error, {:invalid_target, 42}} = Target.resolve(42, s)
    end

    test "atom target that isn't registered errors as :not_registered (atoms are valid but possibly unbound)" do
      s = scope()

      assert {:error, {:not_registered, :totally_unknown_spec_xxx}} =
               Target.resolve(:totally_unknown_spec_xxx, s)
    end
  end

  describe "classify/1" do
    test "in-tree forms" do
      assert Target.classify(:parent) == :in_tree
      assert Target.classify(:screen) == :in_tree
      assert Target.classify({:component, :foo}) == :in_tree
    end

    test "external forms" do
      assert Target.classify(:my_registered) == :external
      assert Target.classify(self()) == :external
      assert Target.classify({:via, Registry, {:r, "k"}}) == :external
    end
  end
end
