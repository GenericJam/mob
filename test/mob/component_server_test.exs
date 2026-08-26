defmodule Mob.ComponentServerTest do
  use ExUnit.Case, async: true

  # Mob.ComponentServer.dispatch/3 (the programmatic Elixir API) bypasses the
  # native pipeline entirely — payload arrives as an already-decoded map, not
  # JSON. These tests exercise the actual delivery shape the native bridges
  # send: handle_info({:component_event, event, payload_json}, ...), where
  # event/payload_json may be a binary (the fixed contract, mob 0.7.27+) or a
  # charlist (an older native shell, hot-deployed a newer BEAM — MOB-98).

  defmodule Recorder do
    use Mob.Component

    def mount(_props, socket) do
      {:ok,
       socket
       |> Mob.Socket.assign(:last_event, nil)
       |> Mob.Socket.assign(:last_payload, nil)}
    end

    def render(assigns), do: %{last_event: assigns.last_event, last_payload: assigns.last_payload}

    def handle_event(event, payload, socket) do
      {:noreply,
       socket
       |> Mob.Socket.assign(:last_event, event)
       |> Mob.Socket.assign(:last_payload, payload)}
    end
  end

  setup do
    # Mob.ComponentRegistry registers under a fixed global name. Another
    # async test file (component_test.exs) may have already started it —
    # start_supervised! would raise on {:already_started, _}, so tolerate
    # that instead of racing to be first.
    case start_supervised({Mob.ComponentRegistry, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, pid} =
      Mob.ComponentServer.start(
        module: Recorder,
        id: :r,
        screen_pid: self(),
        props: %{},
        platform: :no_render
      )

    {:ok, pid: pid}
  end

  describe "native :component_event delivery" do
    test "accepts a binary event name and binary JSON payload", %{pid: pid} do
      send(pid, {:component_event, "tapped", ~s({"index":1})})
      assert_receive {:component_changed, :r, Recorder}

      props = Mob.ComponentServer.render_props(pid)
      assert props.last_event == "tapped"
      assert props.last_payload == %{"index" => 1}
    end

    test "accepts a legacy charlist event name and charlist JSON payload", %{pid: pid} do
      send(
        pid,
        {:component_event, String.to_charlist("tapped"), String.to_charlist(~s({"index":1}))}
      )

      assert_receive {:component_changed, :r, Recorder}

      props = Mob.ComponentServer.render_props(pid)
      assert props.last_event == "tapped"
      assert props.last_payload == %{"index" => 1}
    end

    test "the component always receives a binary event name, never a charlist", %{pid: pid} do
      send(pid, {:component_event, String.to_charlist("charlist_event"), "{}"})
      assert_receive {:component_changed, :r, Recorder}

      assert Mob.ComponentServer.render_props(pid).last_event == "charlist_event"
    end

    test "malformed JSON falls back to an empty map instead of crashing the component", %{
      pid: pid
    } do
      send(pid, {:component_event, "bad", "not json"})
      assert_receive {:component_changed, :r, Recorder}

      assert Mob.ComponentServer.render_props(pid).last_payload == %{}
      assert Process.alive?(pid)
    end

    test "valid but non-map JSON falls back to an empty map", %{pid: pid} do
      send(pid, {:component_event, "bad", "5"})
      assert_receive {:component_changed, :r, Recorder}

      assert Mob.ComponentServer.render_props(pid).last_payload == %{}
    end

    test "an unexpected event shape doesn't crash the component", %{pid: pid} do
      send(pid, {:component_event, :not_a_string, "{}"})
      assert_receive {:component_changed, :r, Recorder}

      assert Mob.ComponentServer.render_props(pid).last_event == ""
      assert Process.alive?(pid)
    end
  end

  describe "to_binary/1" do
    test "a binary passes through unchanged" do
      assert Mob.ComponentServer.to_binary("x") == "x"
    end

    test "a charlist converts to a binary" do
      assert Mob.ComponentServer.to_binary(String.to_charlist("x")) == "x"
    end

    test "an ASCII-only charlist round-trips through List.to_string identically" do
      # Sanity check: for the common case (plain ASCII), byte-preserving
      # conversion and codepoint-encoding conversion agree.
      assert Mob.ComponentServer.to_binary(~c"tapped") == "tapped"
    end

    test "a charlist with a byte > 127 is reproduced byte-for-byte, not UTF-8 encoded" do
      # ERL_NIF_LATIN1 maps codepoint N to byte N — the raw byte 233, not
      # the two-byte UTF-8 encoding of codepoint 233 (é). List.to_string/1
      # would produce <<195, 169>>; the byte-preserving conversion must not.
      assert Mob.ComponentServer.to_binary([233]) == <<233>>
    end

    test "an unexpected shape (neither binary nor list) falls back to an empty binary" do
      assert Mob.ComponentServer.to_binary(:not_a_string) == ""
      assert Mob.ComponentServer.to_binary(nil) == ""
      assert Mob.ComponentServer.to_binary({1, 2}) == ""
    end
  end

  describe "decode_payload/1" do
    test "decodes a binary JSON map" do
      assert Mob.ComponentServer.decode_payload(~s({"a":1})) == %{"a" => 1}
    end

    test "decodes a charlist JSON map" do
      assert Mob.ComponentServer.decode_payload(String.to_charlist(~s({"a":1}))) == %{"a" => 1}
    end

    test "falls back to %{} on malformed JSON" do
      assert Mob.ComponentServer.decode_payload("not json") == %{}
    end

    test "falls back to %{} on valid but non-map JSON" do
      assert Mob.ComponentServer.decode_payload("5") == %{}
      assert Mob.ComponentServer.decode_payload("null") == %{}
      assert Mob.ComponentServer.decode_payload("[1,2]") == %{}
    end
  end
end
