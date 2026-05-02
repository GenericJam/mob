defmodule Mob.Event.AddressTest do
  use ExUnit.Case, async: true
  doctest Mob.Event.Address

  alias Mob.Event.Address

  describe "new/1" do
    test "builds a minimal address" do
      addr = Address.new(screen: MyScreen, widget: :button, id: :save)
      assert addr.screen == MyScreen
      assert addr.widget == :button
      assert addr.id == :save
      assert addr.component_path == []
      assert addr.instance == nil
      assert addr.render_id == 1
    end

    test "honors all keys" do
      addr =
        Address.new(
          screen: MyScreen,
          component_path: [:form, :inner],
          widget: :text_field,
          id: :email,
          instance: 7,
          render_id: 42
        )

      assert addr.component_path == [:form, :inner]
      assert addr.instance == 7
      assert addr.render_id == 42
    end

    test "raises if required keys are missing" do
      assert_raise KeyError, fn -> Address.new(widget: :button, id: :x) end
      assert_raise KeyError, fn -> Address.new(screen: MyScreen, id: :x) end
      assert_raise KeyError, fn -> Address.new(screen: MyScreen, widget: :button) end
    end
  end

  describe "validate_id/1" do
    test "accepts atoms" do
      assert Address.validate_id(:save) == :ok
      assert Address.validate_id(:complex_atom_with_underscores) == :ok
      assert Address.validate_id(true) == :ok
      assert Address.validate_id(false) == :ok
    end

    test "accepts binaries" do
      assert Address.validate_id("save") == :ok
      assert Address.validate_id("contact:1234") == :ok
      assert Address.validate_id("") == :ok
    end

    test "accepts integers" do
      assert Address.validate_id(0) == :ok
      assert Address.validate_id(-7) == :ok
      assert Address.validate_id(42) == :ok
    end

    test "accepts floats (allowed but discouraged)" do
      assert Address.validate_id(1.5) == :ok
    end

    test "accepts tuples" do
      assert Address.validate_id({:user, 42}) == :ok
      assert Address.validate_id({}) == :ok
    end

    test "accepts lists" do
      assert Address.validate_id([1, 2, 3]) == :ok
      assert Address.validate_id([]) == :ok
    end

    test "accepts plain maps" do
      assert Address.validate_id(%{key: 1}) == :ok
      assert Address.validate_id(%{}) == :ok
    end

    test "rejects nil" do
      assert Address.validate_id(nil) == {:error, :nil_not_allowed}
    end

    test "rejects pids" do
      assert Address.validate_id(self()) == {:error, :pid_not_allowed}
    end

    test "rejects refs" do
      assert Address.validate_id(make_ref()) == {:error, :reference_not_allowed}
    end

    test "rejects funs" do
      assert Address.validate_id(fn -> :x end) == {:error, :function_not_allowed}
    end

    # structs are special — they're maps, but we reject because they often carry pids
    # and won't survive serialisation cleanly
    test "rejects structs (they're maps but often non-serializable)" do
      assert {:error, _} =
               Address.validate_id(%Address{screen: MyScreen, widget: :button, id: :x})
    end
  end

  describe "same_widget?/2" do
    test "true for identical addresses ignoring render_id" do
      a = Address.new(screen: MyScreen, widget: :button, id: :save, render_id: 1)
      b = Address.new(screen: MyScreen, widget: :button, id: :save, render_id: 99)
      assert Address.same_widget?(a, b)
    end

    test "false when widget differs" do
      a = Address.new(screen: MyScreen, widget: :button, id: :save)
      b = Address.new(screen: MyScreen, widget: :text_field, id: :save)
      refute Address.same_widget?(a, b)
    end

    test "false when id differs" do
      a = Address.new(screen: MyScreen, widget: :button, id: :save)
      b = Address.new(screen: MyScreen, widget: :button, id: :cancel)
      refute Address.same_widget?(a, b)
    end

    test "false when component_path differs" do
      a = Address.new(screen: MyScreen, component_path: [:a], widget: :button, id: :save)
      b = Address.new(screen: MyScreen, component_path: [:b], widget: :button, id: :save)
      refute Address.same_widget?(a, b)
    end

    test "false when instance differs (list rows)" do
      a = Address.new(screen: MyScreen, widget: :list, id: :c, instance: 1)
      b = Address.new(screen: MyScreen, widget: :list, id: :c, instance: 2)
      refute Address.same_widget?(a, b)
    end

    test "true when both have same instance" do
      a = Address.new(screen: MyScreen, widget: :list, id: :c, instance: 7)
      b = Address.new(screen: MyScreen, widget: :list, id: :c, instance: 7)
      assert Address.same_widget?(a, b)
    end
  end

  describe "current?/2" do
    test "true when render_id matches" do
      addr = Address.new(screen: S, widget: :button, id: :x, render_id: 5)
      assert Address.current?(addr, 5)
    end

    test "false when render_id is older than current" do
      addr = Address.new(screen: S, widget: :button, id: :x, render_id: 3)
      refute Address.current?(addr, 5)
    end

    test "false when render_id is newer than current (shouldn't happen but be safe)" do
      addr = Address.new(screen: S, widget: :button, id: :x, render_id: 8)
      refute Address.current?(addr, 5)
    end
  end

  describe "with_render_id/2" do
    test "returns a new address with updated render_id" do
      a = Address.new(screen: S, widget: :button, id: :x, render_id: 1)
      b = Address.with_render_id(a, 42)
      assert b.render_id == 42
      # original unchanged
      assert a.render_id == 1
      # other fields preserved
      assert Address.same_widget?(a, b)
    end
  end

  describe "to_string/1" do
    test "formats screen and widget" do
      addr = Address.new(screen: MyApp.MyScreen, widget: :button, id: :save)
      assert Address.to_string(addr) == "MyApp.MyScreen→button#save"
    end

    test "includes component_path with /" do
      addr = Address.new(screen: S, component_path: [:form, :inner], widget: :button, id: :save)
      assert Address.to_string(addr) == "S/form/inner→button#save"
    end

    test "includes instance in []" do
      addr = Address.new(screen: S, widget: :list, id: :contacts, instance: 47)
      assert Address.to_string(addr) == "S→list#contacts[47]"
    end

    test "binary id renders as-is" do
      addr = Address.new(screen: S, widget: :card, id: "contact:42")
      assert Address.to_string(addr) == "S→card#contact:42"
    end

    test "tuple id is inspected" do
      addr = Address.new(screen: S, widget: :card, id: {:user, 42})
      assert Address.to_string(addr) == "S→card##{inspect({:user, 42})}"
    end

    test "String.Chars protocol works" do
      addr = Address.new(screen: S, widget: :button, id: :x)
      assert "#{addr}" == "S→button#x"
    end

    test "Inspect protocol shows render_id" do
      addr = Address.new(screen: S, widget: :button, id: :x, render_id: 7)
      assert inspect(addr) == "#Mob.Event.Address<S→button#x@7>"
    end
  end

  describe "pattern matching ergonomics" do
    test "match on widget kind" do
      addr = Address.new(screen: S, widget: :button, id: :save)
      assert match?(%Address{widget: :button}, addr)
    end

    test "match on widget id" do
      addr = Address.new(screen: S, widget: :button, id: :save)
      assert match?(%Address{id: :save}, addr)
      refute match?(%Address{id: :other}, addr)
    end

    test "match on component_path prefix" do
      addr = Address.new(screen: S, component_path: [:form, :inner], widget: :button, id: :save)
      assert match?(%Address{component_path: [:form | _]}, addr)
    end

    test "binary id pattern match" do
      addr = Address.new(screen: S, widget: :card, id: "contact:42")
      assert match?(%Address{id: "contact:" <> _rest}, addr)
    end

    test "tuple id pattern match" do
      addr = Address.new(screen: S, widget: :row, id: {:user, 42})
      assert match?(%Address{id: {:user, _}}, addr)
    end
  end
end
