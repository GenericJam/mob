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

  defmodule ComponentScreen do
    use Mob.Screen

    def mount(_params, _session, socket), do: {:ok, socket}

    def render(_assigns) do
      Mob.UI.native_view(Mob.ComponentServerTest.Recorder, id: :owned)
    end
  end

  defmodule BlockingTermination do
    use Mob.Component

    def mount(%{observer: observer}, socket),
      do: {:ok, Mob.Socket.assign(socket, :observer, observer)}

    def render(_assigns), do: %{}

    def terminate(reason, socket) do
      send(socket.assigns.observer, {:component_terminating, self(), reason})

      receive do
        :release -> :ok
      end
    end
  end

  defmodule RaisingTermination do
    use Mob.Component

    def mount(%{observer: observer}, socket),
      do: {:ok, Mob.Socket.assign(socket, :observer, observer)}

    def render(_assigns), do: %{}

    def terminate(reason, socket) do
      send(socket.assigns.observer, {:component_terminating, self(), reason})
      raise "hostile terminate callback"
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

      def platform, do: :ios
      def safe_area, do: {0.0, 0.0, 0.0, 0.0}
      def clear_taps, do: :ok
      def register_tap(_tag), do: 0
      def set_transition(_transition), do: :ok
      def set_root(_json), do: :ok

      def reset,
        do:
          Agent.update(__MODULE__, fn _ -> %{calls: [], next: 0, freed: [], result: :allocate} end)

      # :allocate — a real freelist pool: reuse a freed slot before growing.
      # :exhausted — always report the pool full, like the real pool at capacity.
      # :legacy_int / :legacy_badarg — simulate a native binary older than
      # MOB-100 (mix mob.push can hot-deploy this BEAM onto native code that
      # wasn't rebuilt with `mix mob.deploy --native`): the pre-fix contract
      # returned a bare int on success and raised (enif_make_badarg) on
      # exhaustion, neither of which matches {:ok, _} / {:error, _}.
      def set_result(result), do: Agent.update(__MODULE__, &%{&1 | result: result})

      def register_component(pid) do
        # :legacy_badarg must raise in the CALLING process (matching a real
        # NIF's enif_make_badarg), not inside this Agent's own process —
        # so the Agent only ever returns a marker; the raise happens below,
        # back in the caller.
        case Agent.get_and_update(__MODULE__, fn s ->
               calls = [{:register_component, [pid]} | s.calls]

               case s.result do
                 :allocate ->
                   case s.freed do
                     [handle | rest] -> {{:ok, handle}, %{s | calls: calls, freed: rest}}
                     [] -> {{:ok, s.next}, %{s | calls: calls, next: s.next + 1}}
                   end

                 :exhausted ->
                   {{:error, :component_slots_exhausted}, %{s | calls: calls}}

                 :legacy_int ->
                   {s.next, %{s | calls: calls, next: s.next + 1}}

                 :legacy_badarg ->
                   {:legacy_badarg_marker, %{s | calls: calls}}
               end
             end) do
          :legacy_badarg_marker -> raise ArgumentError, "argument error"
          other -> other
        end
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

    test "a component terminates and releases its handle when its screen dies" do
      screen_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} =
        Mob.ComponentServer.start(
          module: Recorder,
          id: :owned,
          screen_pid: screen_pid,
          props: %{},
          platform: :ios,
          nif: MockNIF
        )

      assert Mob.ComponentServer.get_handle(pid) == 0
      assert {:ok, ^pid} = Mob.ComponentRegistry.lookup(screen_pid, :owned, Recorder)

      ref = Process.monitor(pid)
      Process.exit(screen_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
      assert {:error, :not_found} = Mob.ComponentRegistry.lookup(screen_pid, :owned, Recorder)
      assert {:deregister_component, [0]} in MockNIF.calls()
    end

    test "a blocking component terminate callback cannot hold up its owner" do
      screen_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, component_pid} =
        Mob.ComponentServer.start(
          module: BlockingTermination,
          id: :blocking,
          screen_pid: screen_pid,
          props: %{observer: self()},
          platform: :ios,
          nif: MockNIF
        )

      screen_ref = Process.monitor(screen_pid)
      Process.exit(screen_pid, :kill)

      assert_receive {:DOWN, ^screen_ref, :process, ^screen_pid, :killed}, 100
      assert_receive {:component_terminating, ^component_pid, :killed}, 500

      assert {:error, :not_found} =
               Mob.ComponentRegistry.lookup(screen_pid, :blocking, BlockingTermination)

      assert {:deregister_component, [0]} in MockNIF.calls()
      Process.exit(component_pid, :kill)
    end

    test "a raising component terminate callback cannot affect its owner or leak its handle" do
      screen_pid = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, component_pid} =
        Mob.ComponentServer.start(
          module: RaisingTermination,
          id: :raising,
          screen_pid: screen_pid,
          props: %{observer: self()},
          platform: :ios,
          nif: MockNIF
        )

      screen_ref = Process.monitor(screen_pid)
      component_ref = Process.monitor(component_pid)
      Process.exit(screen_pid, :kill)

      assert_receive {:DOWN, ^screen_ref, :process, ^screen_pid, :killed}, 100
      assert_receive {:component_terminating, ^component_pid, :killed}, 500
      assert_receive {:DOWN, ^component_ref, :process, ^component_pid, _reason}, 500

      assert {:error, :not_found} =
               Mob.ComponentRegistry.lookup(screen_pid, :raising, RaisingTermination)

      assert {:deregister_component, [0]} in MockNIF.calls()
    end

    test "an old component cannot deregister its replacement" do
      screen_pid = self()

      {:ok, old_pid} =
        Mob.ComponentServer.start(
          module: Recorder,
          id: :replaced,
          screen_pid: screen_pid,
          props: %{},
          platform: :ios,
          nif: MockNIF
        )

      :ok = :sys.suspend(old_pid)
      Mob.ComponentRegistry.reconcile(screen_pid, MapSet.new())

      {:ok, replacement_pid} =
        Mob.ComponentServer.start(
          module: Recorder,
          id: :replaced,
          screen_pid: screen_pid,
          props: %{},
          platform: :ios,
          nif: MockNIF
        )

      assert {:ok, ^replacement_pid} =
               Mob.ComponentRegistry.lookup(screen_pid, :replaced, Recorder)

      old_ref = Process.monitor(old_pid)
      :ok = :sys.resume(old_pid)
      assert_receive {:DOWN, ^old_ref, :process, ^old_pid, :shutdown}, 500

      assert {:ok, ^replacement_pid} =
               Mob.ComponentRegistry.lookup(screen_pid, :replaced, Recorder)

      assert Process.alive?(replacement_pid)
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

    test "a pre-MOB-100 native binary's bare-int return degrades instead of crashing" do
      MockNIF.set_result(:legacy_int)

      log =
        capture_log(fn ->
          {:ok, pid} =
            Mob.ComponentServer.start(
              module: Recorder,
              id: :legacy_int,
              screen_pid: self(),
              props: %{},
              platform: :ios,
              nif: MockNIF
            )

          assert Process.alive?(pid)
          assert Mob.ComponentServer.get_handle(pid) == -1
        end)

      assert log =~ "unexpected register_component/1 return"
    end

    test "a pre-MOB-100 native binary raising badarg on exhaustion degrades instead of crashing" do
      MockNIF.set_result(:legacy_badarg)

      log =
        capture_log(fn ->
          {:ok, pid} =
            Mob.ComponentServer.start(
              module: Recorder,
              id: :legacy_badarg,
              screen_pid: self(),
              props: %{},
              platform: :ios,
              nif: MockNIF
            )

          assert Process.alive?(pid)
          assert Mob.ComponentServer.get_handle(pid) == -1
        end)

      assert log =~ "register_component/1 raised"
    end

    test "register/reconcile/register cycling does not leak slots (MOB-100 root cause)" do
      # Exercises the production reconciliation path used both after a render
      # and while a screen terminates.
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

        # Keep the monitor assertion so a future asynchronous implementation
        # cannot make the next cycle race the old registration.
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
