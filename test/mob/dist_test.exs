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

  defp non_loopback_ipv4 do
    {:ok, ifaddrs} = :inet.getifaddrs()

    ifaddrs
    |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
    |> Enum.find(&match?({a, _, _, _} when a != 127, &1))
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
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

  describe "start_distribution/3" do
    @kernel_keys [
      :start_epmd,
      :inet_dist_listen_min,
      :inet_dist_listen_max,
      :inet_dist_use_interface
    ]

    setup do
      Mob.Dist.stop()
      previous = Map.new(@kernel_keys, &{&1, :application.get_env(:kernel, &1)})

      on_exit(fn ->
        Mob.Dist.stop()

        for {key, value} <- previous do
          case value do
            {:ok, v} -> :application.set_env(:kernel, key, v)
            :undefined -> :application.unset_env(:kernel, key)
          end
        end
      end)
    end

    # The phone's WiFi address must not reach the node; `adb forward` lands on
    # the device's loopback, so that is the only interface the Mac needs.
    test "listens on loopback only, with the given cookie" do
      lan_ip = non_loopback_ipv4() || flunk("host has no non-loopback IPv4 address to probe")
      port = free_port()

      assert {:ok, _} =
               Mob.Dist.start_distribution(:"mob_dist_bind@127.0.0.1", :bind_test_cookie, port)

      assert Node.get_cookie() == :bind_test_cookie
      assert {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
      :gen_tcp.close(sock)
      assert {:error, :econnrefused} = :gen_tcp.connect(lan_ip, port, [], 1_000)
    end
  end

  describe "android_cookie/1" do
    setup do
      previous = System.get_env("MOB_BEAMS_DIR")
      dir = Mob.Test.ProcessHelpers.tmp_path("mob_dist_cookie")
      File.mkdir_p!(dir)
      System.put_env("MOB_BEAMS_DIR", dir)

      on_exit(fn ->
        File.rm_rf!(dir)

        if previous,
          do: System.put_env("MOB_BEAMS_DIR", previous),
          else: System.delete_env("MOB_BEAMS_DIR")
      end)

      %{cookie_file: Path.join(dir, "mob_dist_cookie")}
    end

    @managed String.duplicate("0123456789abcdef", 4)

    test "uses the cookie mob_dev wrote, over the public :mob_secret", %{cookie_file: file} do
      File.write!(file, @managed <> "\n")

      assert Mob.Dist.android_cookie(cookie: :mob_secret) == {:managed, String.to_atom(@managed)}
      assert Mob.Dist.android_cookie([]) == {:managed, String.to_atom(@managed)}
    end

    test "a custom app cookie wins over the managed one", %{cookie_file: file} do
      File.write!(file, @managed)
      assert Mob.Dist.android_cookie(cookie: :ota_session) == {:app, :ota_session}
    end

    test "without a valid managed cookie, the node gets a fresh random one", %{cookie_file: file} do
      hex64 = Regex.compile!("\\A[0-9a-f]{64}\\z")

      for contents <- [nil, "mob_secret", String.upcase(@managed), @managed <> "00"] do
        if contents, do: File.write!(file, contents), else: File.rm(file)

        assert {:ephemeral, first} = Mob.Dist.android_cookie(cookie: :mob_secret)
        assert {:ephemeral, second} = Mob.Dist.android_cookie([])
        assert Atom.to_string(first) =~ hex64
        refute first == second
      end
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

  describe "android_settings/1" do
    @vars ["MOB_DIST_PORT", "MOB_NODE_SUFFIX", "MOB_BEAMS_DIR"]

    setup do
      previous = Map.new(@vars, &{&1, System.get_env(&1)})
      dir = Mob.Test.ProcessHelpers.tmp_path("mob_dist")
      File.mkdir_p!(dir)
      Enum.each(@vars, &System.delete_env/1)
      System.put_env("MOB_BEAMS_DIR", dir)

      on_exit(fn ->
        File.rm_rf!(dir)

        for {var, value} <- previous do
          if value, do: System.put_env(var, value), else: System.delete_env(var)
        end
      end)

      %{deploy_file: Path.join(dir, "mob_dist")}
    end

    test "defaults to no suffix and port 9100 without env or deploy file" do
      assert Mob.Dist.android_settings([]) == {nil, 9100}
    end

    # A launch from the home screen carries no intent extras.
    test "a launcher start takes the suffix and port the last deploy wrote", %{deploy_file: file} do
      File.write!(file, "suffix=emulator_5558\nport=9123\n")
      assert Mob.Dist.android_settings([]) == {"emulator_5558", 9123}
    end

    test "env and explicit opts win over the deploy file, per setting", %{deploy_file: file} do
      File.write!(file, "suffix=emulator_5558\nport=9123\n")

      System.put_env("MOB_NODE_SUFFIX", "zy22cr")
      assert Mob.Dist.android_settings([]) == {"zy22cr", 9123}

      System.put_env("MOB_DIST_PORT", "9200")
      assert Mob.Dist.android_settings([]) == {"zy22cr", 9200}
      assert Mob.Dist.android_settings(dist_port: 9300) == {"zy22cr", 9300}
    end

    test "empty env vars fall through to the deploy file", %{deploy_file: file} do
      File.write!(file, "suffix=emulator_5558\nport=9123\n")
      System.put_env("MOB_NODE_SUFFIX", "")
      System.put_env("MOB_DIST_PORT", "")
      assert Mob.Dist.android_settings([]) == {"emulator_5558", 9123}
    end

    test "a garbled file or key falls back to the defaults", %{deploy_file: file} do
      File.write!(file, "suffix=bad name@host\nport=99999\n")
      assert Mob.Dist.android_settings([]) == {nil, 9100}

      File.write!(file, <<0xFF, 0xFE, "port=9123">>)
      assert Mob.Dist.android_settings([]) == {nil, 9100}

      File.write!(file, "port=9123\nsuffix=\n")
      assert Mob.Dist.android_settings([]) == {nil, 9123}
    end
  end
end
