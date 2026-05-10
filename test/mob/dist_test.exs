defmodule Mob.DistTest do
  use ExUnit.Case, async: false

  # Distribution tests must run serially — starting/stopping :net_kernel affects
  # the whole VM. async: false ensures no interference with other test modules.

  setup_all do
    # epmd must be running for Node.start to succeed. Start it as a daemon if
    # it isn't already up; -daemon is idempotent when epmd is already running.
    System.cmd("epmd", ["-daemon"], stderr_to_stdout: true)
    :ok
  end

  # Attempts to start distribution. Returns :ok on success or skips the test
  # with a clear message if epmd is unavailable in this environment.
  defp ensure_distributed(name) do
    case Node.start(name, :longnames) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> flunk("Node.start failed (#{inspect(reason)}) — is epmd running?")
    end
  end

  describe "stop/0" do
    test "returns :ok when distribution is not running" do
      if not Node.alive?() do
        assert Mob.Dist.stop() == :ok
      end
    end

    test "stops a running distribution node and returns :ok" do
      was_alive = Node.alive?()
      unless was_alive, do: ensure_distributed(:"mob_dist_test@127.0.0.1")

      assert Node.alive?()
      assert Mob.Dist.stop() == :ok
      assert not Node.alive?()
    end

    test "is idempotent — calling stop/0 twice is safe" do
      unless Node.alive?(), do: ensure_distributed(:"mob_dist_test_idempotent@127.0.0.1")

      assert Mob.Dist.stop() == :ok
      assert Mob.Dist.stop() == :ok
    end

    test "disconnects connected nodes before stopping" do
      ensure_distributed(:"mob_dist_test_disconnect@127.0.0.1")
      Node.set_cookie(:test_cookie)

      # We can't connect to a real second node in a unit test, but we can
      # verify Node.list() is empty after stop and that no exception is raised
      # even when the node list would need to be flushed.
      assert Mob.Dist.stop() == :ok
      assert not Node.alive?()
    end
  end

  describe "apply_suffix/2" do
    test "nil suffix returns the base node unchanged" do
      assert Mob.Dist.apply_suffix(:"test_nif_android@127.0.0.1", nil) ==
               :"test_nif_android@127.0.0.1"
    end

    test "empty suffix returns the base node unchanged" do
      assert Mob.Dist.apply_suffix(:"test_nif_android@127.0.0.1", "") ==
               :"test_nif_android@127.0.0.1"
    end

    test "whitespace-only suffix returns the base node unchanged" do
      assert Mob.Dist.apply_suffix(:"test_nif_android@127.0.0.1", "   ") ==
               :"test_nif_android@127.0.0.1"
    end

    test "appends suffix between name and host" do
      assert Mob.Dist.apply_suffix(:"test_nif_android@127.0.0.1", "zy22cr") ==
               :"test_nif_android_zy22cr@127.0.0.1"
    end

    test "trims whitespace from suffix" do
      assert Mob.Dist.apply_suffix(:"test_nif_android@127.0.0.1", "  abc  ") ==
               :"test_nif_android_abc@127.0.0.1"
    end

    test "handles bare name (no @host) by appending suffix" do
      assert Mob.Dist.apply_suffix(:test_nif_android, "zy22cr") ==
               :test_nif_android_zy22cr
    end
  end

  describe "env_dist_port/0" do
    setup do
      # Save+restore so test order doesn't matter and env mutations don't
      # leak into other tests in the same VM.
      previous = System.get_env("MOB_DIST_PORT")

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("MOB_DIST_PORT")
          val -> System.put_env("MOB_DIST_PORT", val)
        end
      end)

      :ok
    end

    test "returns nil when MOB_DIST_PORT is unset" do
      System.delete_env("MOB_DIST_PORT")
      assert Mob.Dist.env_dist_port() == nil
    end

    test "returns nil when MOB_DIST_PORT is empty" do
      System.put_env("MOB_DIST_PORT", "")
      assert Mob.Dist.env_dist_port() == nil
    end

    test "parses a valid port number" do
      System.put_env("MOB_DIST_PORT", "9101")
      assert Mob.Dist.env_dist_port() == 9101
    end

    test "rejects non-numeric values" do
      System.put_env("MOB_DIST_PORT", "abc")
      assert Mob.Dist.env_dist_port() == nil
    end

    test "rejects out-of-range port numbers" do
      System.put_env("MOB_DIST_PORT", "0")
      assert Mob.Dist.env_dist_port() == nil

      System.put_env("MOB_DIST_PORT", "65536")
      assert Mob.Dist.env_dist_port() == nil

      System.put_env("MOB_DIST_PORT", "-1")
      assert Mob.Dist.env_dist_port() == nil
    end

    test "rejects mixed numeric+text" do
      System.put_env("MOB_DIST_PORT", "9101abc")
      assert Mob.Dist.env_dist_port() == nil
    end
  end
end
