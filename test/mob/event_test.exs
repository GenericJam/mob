defmodule Mob.EventTest do
  use ExUnit.Case, async: true
  doctest Mob.Event

  alias Mob.Event
  alias Mob.Event.Address

  defp addr(opts \\ []) do
    Address.new(
      Keyword.merge(
        [screen: TestScreen, widget: :button, id: :save],
        opts
      )
    )
  end

  defp scope(opts \\ []) do
    %{
      screen_pid: Keyword.get(opts, :screen_pid, self()),
      component_chain: Keyword.get(opts, :component_chain, [])
    }
  end

  describe "dispatch/4" do
    test "delivers the canonical envelope to the pid" do
      a = addr()
      :ok = Event.dispatch(self(), a, :tap, nil)
      assert_receive {:mob_event, ^a, :tap, nil}
    end

    test "preserves payload" do
      a = addr(widget: :text_field, id: :email)
      :ok = Event.dispatch(self(), a, :change, "user@example.com")
      assert_receive {:mob_event, ^a, :change, "user@example.com"}
    end

    test "raises on non-pid (caller bug)" do
      assert_raise FunctionClauseError, fn ->
        Event.dispatch(:not_a_pid, addr(), :tap, nil)
      end
    end
  end

  describe "emit/5 — resolved targets" do
    test "delivers via :screen target" do
      a = addr()
      :ok = Event.emit(a, :tap, nil, :screen, scope(screen_pid: self()))
      assert_receive {:mob_event, ^a, :tap, nil}
    end

    test "delivers via :parent target — no components → screen" do
      a = addr()
      :ok = Event.emit(a, :tap, nil, :parent, scope(screen_pid: self()))
      assert_receive {:mob_event, ^a, :tap, nil}
    end

    test "delivers via :parent target — innermost component" do
      a = addr()
      :ok = Event.emit(a, :tap, nil, :parent, scope(component_chain: [{:form, self()}]))
      assert_receive {:mob_event, ^a, :tap, nil}
    end

    test "delivers via {:component, id}" do
      a = addr()

      :ok =
        Event.emit(a, :tap, nil, {:component, :form}, scope(component_chain: [{:form, self()}]))

      assert_receive {:mob_event, ^a, :tap, nil}
    end

    test "drops silently when target unresolvable" do
      a = addr()
      # No subscribers, but emit returns :ok regardless
      :ok = Event.emit(a, :tap, nil, {:component, :ghost}, scope())
      refute_receive {:mob_event, _, _, _}, 50
    end

    test "drops silently when atom name not registered" do
      a = addr()
      :ok = Event.emit(a, :tap, nil, :__no_such_name_ever__, scope())
      refute_receive {:mob_event, _, _, _}, 50
    end
  end

  describe "is_event?/1" do
    test "true for canonical envelope" do
      assert Event.is_event?({:mob_event, addr(), :tap, nil})
    end

    test "false for legacy {:tap, tag} shape" do
      refute Event.is_event?({:tap, :foo})
    end

    test "false for arbitrary tuple" do
      refute Event.is_event?({:something, :else})
      refute Event.is_event?({:mob_event, %{not: "an address"}, :tap, nil})
    end

    test "false for non-tuple" do
      refute Event.is_event?(:atom)
      refute Event.is_event?("string")
    end
  end

  describe "match_address?/2" do
    test "single field match" do
      a = addr(widget: :button, id: :save)
      assert Event.match_address?(a, widget: :button)
      refute Event.match_address?(a, widget: :text_field)
    end

    test "multiple field match" do
      a = addr(widget: :button, id: :save)
      assert Event.match_address?(a, widget: :button, id: :save)
      refute Event.match_address?(a, widget: :button, id: :cancel)
    end

    test "matches instance" do
      a = addr(widget: :list, id: :contacts, instance: 47)
      assert Event.match_address?(a, instance: 47)
      refute Event.match_address?(a, instance: 48)
    end

    test "empty filter matches everything" do
      assert Event.match_address?(addr(), [])
    end
  end

  describe "send_test/7" do
    test "delivers a synthesized event" do
      :ok = Event.send_test(self(), MyScreen, :button, :save, :tap)

      assert_receive {:mob_event, %Address{screen: MyScreen, widget: :button, id: :save}, :tap,
                      nil}
    end

    test "honors instance and render_id options" do
      :ok =
        Event.send_test(self(), MyScreen, :list, :contacts, :select, nil,
          instance: 47,
          render_id: 12
        )

      assert_receive {:mob_event,
                      %Address{
                        screen: MyScreen,
                        widget: :list,
                        id: :contacts,
                        instance: 47,
                        render_id: 12
                      }, :select, nil}
    end

    test "delivers payload" do
      :ok = Event.send_test(self(), MyScreen, :text_field, :email, :change, "x@y")
      assert_receive {:mob_event, _, :change, "x@y"}
    end
  end
end
