defmodule Mob.Event.BridgeTest do
  use ExUnit.Case, async: true
  doctest Mob.Event.Bridge

  alias Mob.Event.{Address, Bridge}

  describe "legacy_to_canonical/3 — :tap" do
    test "atom tag produces a button event" do
      assert {:ok, {:mob_event, addr, :tap, nil}} =
               Bridge.legacy_to_canonical({:tap, :save}, MyScreen)

      assert addr.screen == MyScreen
      assert addr.widget == :button
      assert addr.id == :save
      assert addr.instance == nil
    end

    test "binary tag works (data-derived id)" do
      assert {:ok, {:mob_event, addr, :tap, nil}} =
               Bridge.legacy_to_canonical({:tap, "contact:42"}, MyScreen)

      assert addr.id == "contact:42"
    end

    test "tuple tag works (compound id)" do
      assert {:ok, {:mob_event, addr, :tap, nil}} =
               Bridge.legacy_to_canonical({:tap, {:user, 42}}, MyScreen)

      assert addr.id == {:user, 42}
    end

    test "widget kind can be overridden via opts" do
      assert {:ok, {:mob_event, addr, :tap, nil}} =
               Bridge.legacy_to_canonical({:tap, :submit}, MyScreen, widget: :pressable)

      assert addr.widget == :pressable
    end

    test "render_id is honored" do
      assert {:ok, {:mob_event, addr, :tap, nil}} =
               Bridge.legacy_to_canonical({:tap, :save}, MyScreen, render_id: 17)

      assert addr.render_id == 17
    end

    test "nil tag passes through (invalid id)" do
      assert :passthrough = Bridge.legacy_to_canonical({:tap, nil}, MyScreen)
    end

    test "pid tag passes through (invalid id)" do
      assert :passthrough = Bridge.legacy_to_canonical({:tap, self()}, MyScreen)
    end
  end

  describe "legacy_to_canonical/3 — list-row select" do
    test "structured list tag produces a list event with instance" do
      assert {:ok, {:mob_event, addr, :select, nil}} =
               Bridge.legacy_to_canonical({:tap, {:list, :contacts, :select, 47}}, MyScreen)

      assert addr.widget == :list
      assert addr.id == :contacts
      assert addr.instance == 47
    end

    test "list_id can be a binary (data-derived)" do
      assert {:ok, {:mob_event, addr, :select, nil}} =
               Bridge.legacy_to_canonical({:tap, {:list, "contacts", :select, 0}}, MyScreen)

      assert addr.id == "contacts"
    end

    test "list-row tap takes precedence over generic :tap rule" do
      # The structured shape must match before the generic {:tap, tag} clause.
      assert {:ok, {:mob_event, addr, :select, _}} =
               Bridge.legacy_to_canonical({:tap, {:list, :x, :select, 0}}, MyScreen)

      assert addr.widget == :list
      refute addr.widget == :button
    end
  end

  describe "legacy_to_canonical/3 — :change" do
    test "atom tag + binary value" do
      assert {:ok, {:mob_event, addr, :change, "user@example.com"}} =
               Bridge.legacy_to_canonical({:change, :email, "user@example.com"}, MyScreen)

      assert addr.widget == :text_field
      assert addr.id == :email
    end

    test "boolean value (toggle)" do
      assert {:ok, {:mob_event, addr, :change, true}} =
               Bridge.legacy_to_canonical({:change, :notifications, true}, MyScreen)

      assert addr.id == :notifications
    end

    test "float value (slider)" do
      assert {:ok, {:mob_event, _addr, :change, 0.75}} =
               Bridge.legacy_to_canonical({:change, :volume, 0.75}, MyScreen)
    end

    test "widget kind can be overridden" do
      assert {:ok, {:mob_event, addr, :change, _}} =
               Bridge.legacy_to_canonical({:change, :enabled, true}, MyScreen, widget: :toggle)

      assert addr.widget == :toggle
    end

    test "nil tag passes through" do
      assert :passthrough = Bridge.legacy_to_canonical({:change, nil, "x"}, MyScreen)
    end
  end

  describe "legacy_to_canonical/3 — passthrough" do
    test "unknown shapes pass through" do
      assert :passthrough = Bridge.legacy_to_canonical({:something_else, :x}, MyScreen)
      assert :passthrough = Bridge.legacy_to_canonical(:atom, MyScreen)
      assert :passthrough = Bridge.legacy_to_canonical("string", MyScreen)
      assert :passthrough = Bridge.legacy_to_canonical(nil, MyScreen)
    end

    test "already-canonical envelope is NOT re-wrapped (passes through)" do
      already =
        {:mob_event,
         %Address{
           screen: S,
           widget: :button,
           id: :x,
           component_path: [],
           instance: nil,
           render_id: 1
         }, :tap, nil}

      assert :passthrough = Bridge.legacy_to_canonical(already, MyScreen)
    end
  end

  describe "legacy_to_canonical/3 — IME composition" do
    test ":compose with phase :began" do
      assert {:ok, {:mob_event, addr, :compose, payload}} =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: :began, text: "n"}},
                 MyScreen
               )

      assert addr.widget == :text_field
      assert addr.id == :ime
      assert payload == %{phase: :began, text: "n"}
    end

    test ":compose with phase :updating" do
      assert {:ok, {:mob_event, _, :compose, %{phase: :updating, text: "ni"}}} =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: :updating, text: "ni"}},
                 MyScreen
               )
    end

    test ":compose with phase :committed (CJK character chosen)" do
      assert {:ok, {:mob_event, _, :compose, %{phase: :committed, text: "你"}}} =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: :committed, text: "你"}},
                 MyScreen
               )
    end

    test ":compose with phase :cancelled" do
      assert {:ok, {:mob_event, _, :compose, %{phase: :cancelled, text: ""}}} =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: :cancelled, text: ""}},
                 MyScreen
               )
    end

    test "binary id works for compose" do
      assert {:ok, {:mob_event, addr, :compose, _}} =
               Bridge.legacy_to_canonical(
                 {:compose, "field:email", %{phase: :began, text: ""}},
                 MyScreen
               )

      assert addr.id == "field:email"
    end

    test "missing phase falls through to passthrough" do
      assert :passthrough =
               Bridge.legacy_to_canonical({:compose, :ime, %{text: "x"}}, MyScreen)
    end

    test "non-atom phase falls through" do
      assert :passthrough =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: "began", text: "n"}},
                 MyScreen
               )
    end

    test "nil tag passes through" do
      assert :passthrough =
               Bridge.legacy_to_canonical(
                 {:compose, nil, %{phase: :began, text: ""}},
                 MyScreen
               )
    end

    test "widget kind can be overridden via opts" do
      assert {:ok, {:mob_event, addr, :compose, _}} =
               Bridge.legacy_to_canonical(
                 {:compose, :ime, %{phase: :began, text: ""}},
                 MyScreen,
                 widget: :search_box
               )

      assert addr.widget == :search_box
    end
  end

  describe "legacy_to_canonical/3 — Batch 5 Tier 1: high-frequency events" do
    test ":scroll with payload map" do
      payload = %{x: 0.0, y: 1240.0, dx: 0.0, dy: 12.0, phase: :dragging, ts: 18472, seq: 891}

      assert {:ok, {:mob_event, addr, :scroll, ^payload}} =
               Bridge.legacy_to_canonical({:scroll, :main_list, payload}, MyScreen)

      assert addr.widget == :scroll
      assert addr.id == :main_list
    end

    test ":drag with payload" do
      payload = %{x: 100.0, y: 200.0, dx: 5.0, dy: 0.0, phase: :dragging}

      assert {:ok, {:mob_event, addr, :drag, ^payload}} =
               Bridge.legacy_to_canonical({:drag, :map, payload}, MyScreen)

      assert addr.widget == :drag
    end

    test ":pinch with payload" do
      payload = %{scale: 1.25, velocity: 0.3, phase: :dragging}

      assert {:ok, {:mob_event, _, :pinch, ^payload}} =
               Bridge.legacy_to_canonical({:pinch, :photo, payload}, MyScreen)
    end

    test ":rotate with payload" do
      payload = %{degrees: 45.0, velocity: 0.1, phase: :ended}

      assert {:ok, {:mob_event, _, :rotate, ^payload}} =
               Bridge.legacy_to_canonical({:rotate, :photo, payload}, MyScreen)
    end

    test ":pointer_move with payload" do
      payload = %{x: 320.0, y: 480.0, ts: 12345, seq: 7}

      assert {:ok, {:mob_event, _, :pointer_move, ^payload}} =
               Bridge.legacy_to_canonical({:pointer_move, :hover_zone, payload}, MyScreen)
    end

    test "binary tag works for HF events" do
      assert {:ok, {:mob_event, addr, :scroll, _}} =
               Bridge.legacy_to_canonical({:scroll, "list:contacts", %{}}, MyScreen)

      assert addr.id == "list:contacts"
    end

    test "nil tag passes through" do
      assert :passthrough = Bridge.legacy_to_canonical({:scroll, nil, %{}}, MyScreen)
    end
  end

  describe "legacy_to_canonical/3 — Batch 5 Tier 2: semantic scroll events" do
    test ":scroll_began" do
      assert {:ok, {:mob_event, addr, :scroll_began, nil}} =
               Bridge.legacy_to_canonical({:scroll_began, :main}, MyScreen)

      assert addr.widget == :scroll
      assert addr.id == :main
    end

    test ":scroll_ended" do
      assert {:ok, {:mob_event, _, :scroll_ended, nil}} =
               Bridge.legacy_to_canonical({:scroll_ended, :main}, MyScreen)
    end

    test ":scroll_settled" do
      assert {:ok, {:mob_event, _, :scroll_settled, nil}} =
               Bridge.legacy_to_canonical({:scroll_settled, :main}, MyScreen)
    end

    test ":top_reached" do
      assert {:ok, {:mob_event, _, :top_reached, nil}} =
               Bridge.legacy_to_canonical({:top_reached, :main}, MyScreen)
    end

    test ":scrolled_past" do
      assert {:ok, {:mob_event, _, :scrolled_past, nil}} =
               Bridge.legacy_to_canonical({:scrolled_past, :crossed_100}, MyScreen)
    end

    test "all five Tier-2 events nil tag passes through" do
      for ev <- [:scroll_began, :scroll_ended, :scroll_settled, :top_reached, :scrolled_past] do
        assert :passthrough = Bridge.legacy_to_canonical({ev, nil}, MyScreen)
      end
    end
  end

  describe "legacy_to_canonical!/3" do
    test "returns envelope on success" do
      env = Bridge.legacy_to_canonical!({:tap, :save}, MyScreen)
      assert {:mob_event, %Address{id: :save}, :tap, nil} = env
    end

    test "raises on passthrough" do
      assert_raise ArgumentError, ~r/Not a recognized legacy event/, fn ->
        Bridge.legacy_to_canonical!({:not_an_event, :x}, MyScreen)
      end
    end
  end
end
