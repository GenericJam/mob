defmodule Mob.ComponentServerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

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

  describe "native handle registration (MOB-100)" do
    # A mock :mob_nif backend so these tests can exercise the
    # register_component/deregister_component contract without a device.
    # Agent (not GenServer), unlinked, so it survives across test process
    # boundaries the same way test/mob/renderer_test.exs's MockNIF does.
    defmodule MockNIF do
      use Agent

      def start_link,
        do:
          Agent.start(fn -> %{calls: [], next: 0, freed: [], result: :allocate} end,
            name: __MODULE__
          )

      def calls, do: Agent.get(__MODULE__, & &1.calls)

      def reset,
        do:
          Agent.update(__MODULE__, fn _ -> %{calls: [], next: 0, freed: [], result: :allocate} end)

      # :allocate — a real freelist pool: reuse a freed slot before growing.
      # :exhausted — always report the pool full, like the real pool at capacity.
      def set_result(result), do: Agent.update(__MODULE__, &%{&1 | result: result})

      def register_component(pid) do
        Agent.get_and_update(__MODULE__, fn s ->
          calls = [{:register_component, [pid]} | s.calls]

          case s.result do
            :allocate ->
              case s.freed do
                [handle | rest] -> {{:ok, handle}, %{s | calls: calls, freed: rest}}
                [] -> {{:ok, s.next}, %{s | calls: calls, next: s.next + 1}}
              end

            :exhausted ->
              {{:error, :component_slots_exhausted}, %{s | calls: calls}}
          end
        end)
      end

      def deregister_component(handle) do
        Agent.update(__MODULE__, fn s ->
          %{s | calls: [{:deregister_component, [handle]} | s.calls], freed: [handle | s.freed]}
        end)

        :ok
      end
    end

    setup do
      case start_supervised({Mob.ComponentRegistry, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Unlinked, fixed-name Agent (mirrors test/mob/renderer_test.exs's
      # MockNIF) — reset rather than restarted, since a prior test in this
      # module may have left it running.
      case MockNIF.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      MockNIF.reset()
      :ok
    end

    test ":no_render never calls the native pool and gets the sentinel handle" do
      {:ok, pid} =
        Mob.ComponentServer.start(
          module: Recorder,
          id: :norender,
          screen_pid: self(),
          props: %{},
          platform: :no_render,
          nif: MockNIF
        )

      assert Mob.ComponentServer.get_handle(pid) == -1
      assert MockNIF.calls() == []

      Process.exit(pid, :shutdown)
      # terminate/2 runs asynchronously relative to exit; give it a beat.
      Process.sleep(10)
      assert MockNIF.calls() == []
    end

    test "slot 0 is a valid handle and is deregistered on terminate (no more leak)" do
      {:ok, pid} =
        Mob.ComponentServer.start(
          module: Recorder,
          id: :slot0,
          screen_pid: self(),
          props: %{},
          platform: :ios,
          nif: MockNIF
        )

      assert Mob.ComponentServer.get_handle(pid) == 0

      Process.exit(pid, :shutdown)
      Process.sleep(10)
      assert {:deregister_component, [0]} in MockNIF.calls()
    end

    test "pool exhaustion fails only that component — process survives with the sentinel handle" do
      MockNIF.set_result(:exhausted)

      log =
        capture_log(fn ->
          {:ok, pid} =
            Mob.ComponentServer.start(
              module: Recorder,
              id: :exhausted,
              screen_pid: self(),
              props: %{},
              platform: :ios,
              nif: MockNIF
            )

          assert Process.alive?(pid)
          assert Mob.ComponentServer.get_handle(pid) == -1

          # Still fully functional as an Elixir process — exhaustion only
          # costs native rendering, not the component's own state/events.
          send(pid, {:component_event, "tapped", "{}"})
          assert_receive {:component_changed, :exhausted, Recorder}

          Process.exit(pid, :shutdown)
          Process.sleep(10)
        end)

      assert log =~ "component slot pool exhausted"
      refute {:deregister_component, [-1]} in MockNIF.calls()
    end

    test "register/reconcile/register cycling does not leak slots (MOB-100 root cause)" do
      # Exercises the REAL production stop path: Mob.ComponentRegistry.reconcile/2
      # calls Process.exit(pid, :shutdown) directly (see lib/mob/component_registry.ex),
      # not GenServer.stop. Before trap_exit was added to init/1, that signal
      # terminated the process without ever running terminate/2 — so every
      # screen navigation leaked a slot, independent of the slot-0 sentinel bug.
      screen_pid = self()

      for i <- 1..5 do
        id = :"cycled_#{i}"

        {:ok, pid} =
          Mob.ComponentServer.start(
            module: Recorder,
            id: id,
            screen_pid: screen_pid,
            props: %{},
            platform: :ios,
            nif: MockNIF
          )

        # A real pool with a working freelist hands the same slot back out
        # every time — proof there's no monotonic growth across cycles.
        assert Mob.ComponentServer.get_handle(pid) == 0

        Mob.ComponentRegistry.reconcile(screen_pid, MapSet.new())

        # reconcile/2 exits the process; wait for it to actually be gone
        # before the next cycle re-registers under the same {screen_pid, id}.
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
      end

      assert Enum.count(MockNIF.calls(), &match?({:register_component, _}, &1)) == 5
      assert Enum.count(MockNIF.calls(), &match?({:deregister_component, _}, &1)) == 5
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
