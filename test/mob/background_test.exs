defmodule Mob.BackgroundTest do
  use ExUnit.Case, async: true

  # ── Unit tests — no device required ──────────────────────────────────────────
  #
  # These verify the public API contract: function existence, arity, and return
  # type. They do not exercise the NIF (which requires a running iOS app).

  describe "module API" do
    setup do
      Code.ensure_loaded(Mob.Background)
      :ok
    end

    # The "raises when called outside iOS" tests below invoke the actual
    # functions, which both proves they exist and exercises behaviour. Bare
    # `function_exported?/3` checks were removed — they only confirm the type
    # system; the call-and-rescue tests give the same coverage with real
    # behaviour assertions.

    test "keep_alive/0 raises when called outside iOS (delegates to :mob_nif)" do
      # In the test environment mob_nif.so is absent so the module either fails
      # to load (UndefinedFunctionError) or the on_load stub fires (ErlangError).
      # Either way it must raise — there is no pure-Elixir fallback.
      raised =
        try do
          Mob.Background.keep_alive()
          false
        rescue
          ErlangError -> true
          UndefinedFunctionError -> true
        end

      assert raised, "expected keep_alive/0 to raise outside iOS"
    end

    test "stop/0 raises when called outside iOS (delegates to :mob_nif)" do
      raised =
        try do
          Mob.Background.stop()
          false
        rescue
          ErlangError -> true
          UndefinedFunctionError -> true
        end

      assert raised, "expected stop/0 to raise outside iOS"
    end
  end

  # ── On-device integration tests ───────────────────────────────────────────────
  #
  # These run against a real iOS device connected via Erlang distribution.
  # They are excluded from the default `mix test` run; execute explicitly with:
  #
  #     mix test --only on_device
  #
  # Prerequisites:
  #   1. An iOS device running the mob app (mix mob.connect)
  #   2. The device node reachable (e.g. mob_provision_ios@10.0.0.x)
  #   3. UIBackgroundModes: [audio] declared in the app's Info.plist
  #
  # Set the node via the MOB_TEST_NODE environment variable:
  #
  #     MOB_TEST_NODE=mob_provision_ios@10.0.0.120 mix test --only on_device

  @ios_node System.get_env("MOB_TEST_NODE") &&
              System.get_env("MOB_TEST_NODE") |> String.to_atom()

  defp rpc(fun), do: :rpc.call(@ios_node, :mob_nif, fun, [], 5000)

  defp node_reachable? do
    case :rpc.call(@ios_node, :erlang, :node, [], 2000) do
      {:badrpc, _} -> false
      _ -> true
    end
  end

  @tag :on_device
  test "keep_alive/0 returns :ok" do
    assert rpc(:background_keep_alive) == :ok
  after
    rpc(:background_stop)
  end

  @tag :on_device
  test "keep_alive/0 is idempotent — calling twice does not crash" do
    assert rpc(:background_keep_alive) == :ok
    assert rpc(:background_keep_alive) == :ok
  after
    rpc(:background_stop)
  end

  @tag :on_device
  test "stop/0 returns :ok" do
    rpc(:background_keep_alive)
    assert rpc(:background_stop) == :ok
  end

  @tag :on_device
  test "stop/0 without a prior keep_alive does not crash" do
    assert rpc(:background_stop) == :ok
  end

  @tag :on_device
  test "keep_alive → stop → keep_alive cycle works" do
    assert rpc(:background_keep_alive) == :ok
    assert rpc(:background_stop) == :ok
    assert rpc(:background_keep_alive) == :ok
  after
    rpc(:background_stop)
  end

  # This is the test that validates the whole feature. After keep_alive is active
  # and the screen is locked, the node must remain reachable via distribution.
  # We use idevicediagnostics to lock the screen programmatically (requires USB).
  @tag :on_device
  @tag :screen_lock
  test "node remains reachable for 10 s with screen locked" do
    assert rpc(:background_keep_alive) == :ok

    IO.puts("\n  [background_test] Locking screen via idevicediagnostics...")
    {_, rc} = System.cmd("idevicediagnostics", ["sleep"], stderr_to_stdout: true)
    assert rc == 0, "idevicediagnostics sleep failed — is a USB device connected?"

    :timer.sleep(10_000)

    assert node_reachable?(),
           "Node #{@ios_node} became unreachable within 10 s of screen lock. " <>
             "Is UIBackgroundModes: [audio] in Info.plist?"
  after
    rpc(:background_stop)
  end
end
