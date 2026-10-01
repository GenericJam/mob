defmodule Mob.Dist do
  @moduledoc """
  Platform-aware Erlang distribution startup.

  On iOS, distribution is started at BEAM launch via flags in mob_beam.m
  (`-name mob_demo@127.0.0.1`), so nothing extra is needed here. The
  iOS node name is auto-suffixed per-simulator (from `SIMULATOR_UDID`)
  and can be overridden via `MOB_NODE_SUFFIX` (forwarded by
  `mix mob.deploy --node-suffix` via simctl's `SIMCTL_CHILD_*`
  mechanism, planned).

  On Android, starting distribution at BEAM launch races with Android's hwui
  thread pool initialization (~125ms window), corrupting an internal mutex and
  causing a SIGABRT. The fix is to defer `Node.start/2` until after the UI has
  fully settled.

  Additionally, `mix mob.connect` runs `adb reverse tcp:4369 tcp:4369` to tunnel
  Mac EPMD into the device. OTP's `Node.start/2` would ordinarily spawn a local
  `epmd` daemon that also tries to bind port 4369 — causing a port conflict and
  crash. The fix: set `start_epmd: false` and wait for the ADB-tunnelled EPMD to
  be reachable before calling `Node.start/2`. If the tunnel is not up within 10s
  (standalone launch, no `mix mob.connect`), distribution is skipped gracefully.

  The Android listener binds to loopback only. The Mac reaches it through the
  `adb forward` mob_dev sets up, which connects to the device's own loopback,
  so nothing on the phone's WiFi can reach the distribution port.

  ## Cookie

  The cookie is private per app: `mix mob.deploy` and `mix mob.connect` write
  the project's managed cookie (kept by mob_dev under `~/.mob/dist_cookies/`)
  to `$MOB_BEAMS_DIR/mob_dist_cookie` in the app's private storage, and the
  node uses it. An explicit `:cookie` other than `:mob_secret` takes precedence
  (then pass the same value to `mix mob.connect --cookie`). `:mob_secret`, the
  value generated apps used to embed, is public, so it is ignored. With neither
  a custom nor a managed cookie the node gets a random one and can't be
  attached until mob_dev restarts it.

  ## Usage (in your app's start/0)

      Mob.Dist.ensure_started(node: :"mob_demo@127.0.0.1")

  Options:
  - `:node`   — node name atom, e.g. `:"mob_demo@127.0.0.1"` (required on Android)
  - `:cookie` — custom cookie atom (optional; see above)
  - `:delay`  — ms to wait before starting dist on Android (default: 3_000)
  """

  @default_delay 3_000
  @legacy_cookie :mob_secret
  @cookie_file "mob_dist_cookie"

  @doc """
  Ensure Erlang distribution is running for the current platform.

  - iOS: no-op (dist already started via BEAM args in mob_beam.m).
  - Android: spawns a process that sleeps for `:delay` ms then calls
    `Node.start/2` + `Node.set_cookie/1`, listening on loopback only. Pins the
    dist port to `:dist_port` (default 9100) so mob_dev knows which port to
    forward.

  Options:
  - `:node`      — base node name atom (required on Android)
  - `:cookie`    — custom cookie atom; `:mob_secret` is ignored (see the moduledoc)
  - `:delay`     — ms to wait before starting dist (default: 3_000)
  - `:dist_port` — Erlang dist listen port (default: 9100)

  ## Per-device node names (Android)

  Mac's EPMD only allows one registration per name. Two phones running the
  same app with the same hardcoded `:node` collide — the second to start
  gets `:nodistribution` and silently runs without dist. To keep two or
  more devices distinguishable, set the `MOB_NODE_SUFFIX` env var (the
  Android shell launcher reads `mob_node_suffix` from the launch intent
  extras and exports it). When present, the resolved node becomes
  `<base_name>_<suffix>@<host>` — e.g. `test_nif_android_zy22cr@127.0.0.1`.

  A launch from the home screen carries no intent extras, so `mix mob.deploy`
  also writes the suffix and port it chose to `$MOB_BEAMS_DIR/mob_dist`
  (`suffix=<suffix>` and `port=<port>`, one per line). Each is used when its
  env var is unset or empty, so a launcher restart comes back under the name
  and port the tooling already forwards. A missing or garbled file, or key,
  falls back to the defaults.
  """
  @spec ensure_started(keyword()) :: :ok
  def ensure_started(opts \\ []) do
    cond do
      release_mode?() ->
        # App Store / TestFlight build: distribution is disabled at the C
        # layer (mob_beam.m drops -name/-setcookie when MOB_RELEASE is
        # defined). Skip Node.start so calling apps don't have to special-case
        # release vs dev — same call site, no-ops in release.
        :ok

      true ->
        case :mob_nif.platform() do
          :ios ->
            :ok

          :android ->
            base_node = Keyword.fetch!(opts, :node)
            {cookie_source, cookie} = android_cookie(opts)
            delay = Keyword.get(opts, :delay, @default_delay)
            {suffix, dist_port} = android_settings(opts)
            node = apply_suffix(base_node, suffix)

            if node != base_node do
              :mob_nif.log("Mob.Dist: node suffix applied — #{base_node} → #{node}")
            end

            :mob_nif.log("Mob.Dist: #{cookie_log(cookie_source, opts)}")
            spawn(fn -> start_after(node, cookie, delay, dist_port) end)
            :ok
        end
    end
  end

  @doc false
  @spec release_mode?() :: boolean()
  def release_mode?, do: System.get_env("MOB_RELEASE") == "1"

  @doc false
  @spec apply_suffix(node(), String.t() | nil) :: node()
  def apply_suffix(base_node, nil), do: base_node
  def apply_suffix(base_node, ""), do: base_node

  def apply_suffix(base_node, suffix) when is_binary(suffix) do
    suffix = String.trim(suffix)

    if suffix == "" do
      base_node
    else
      case String.split(Atom.to_string(base_node), "@", parts: 2) do
        [name, host] -> :"#{name}_#{suffix}@#{host}"
        [name] -> :"#{name}_#{suffix}"
      end
    end
  end

  @doc false
  # Resolution order, per setting:
  #   port:   explicit `:dist_port` opt, MOB_DIST_PORT env (set by the Android
  #           launcher from the `mob_dist_port` intent extra — the per-device
  #           port mob_dev's Tunnel allocated), the deploy file, then 9100.
  #   suffix: MOB_NODE_SUFFIX env, then the deploy file.
  #
  # Without the per-device port every device's BEAM listened on 9100 whatever
  # host port mob_dev forwarded; for any non-zero device index the
  # EPMD-broadcast port and the actual forward target disagreed, leaving the
  # second device's BEAM unreachable from the Mac side.
  @spec android_settings(keyword()) :: {String.t() | nil, pos_integer()}
  def android_settings(opts) do
    deployed = deploy_settings()

    suffix =
      case System.get_env("MOB_NODE_SUFFIX") do
        env when env in [nil, ""] -> Map.get(deployed, :suffix)
        env -> env
      end

    port =
      Keyword.get(opts, :dist_port) || env_dist_port() || Map.get(deployed, :port) || 9100

    {suffix, port}
  end

  @doc false
  @spec env_dist_port() :: pos_integer() | nil
  def env_dist_port, do: parse_port(System.get_env("MOB_DIST_PORT"))

  @doc false
  @spec deploy_settings() :: %{optional(:suffix) => String.t(), optional(:port) => pos_integer()}
  def deploy_settings do
    with dir when dir not in [nil, ""] <- System.get_env("MOB_BEAMS_DIR"),
         {:ok, contents} <- File.read(Path.join(dir, "mob_dist")) do
      contents |> String.split("\n") |> Enum.reduce(%{}, &put_deploy_setting/2)
    else
      _ -> %{}
    end
  end

  defp put_deploy_setting(line, acc) do
    case line |> String.trim() |> String.split("=", parts: 2) do
      ["suffix", suffix] ->
        if valid_suffix?(suffix), do: Map.put(acc, :suffix, suffix), else: acc

      ["port", raw] ->
        case parse_port(raw) do
          nil -> acc
          port -> Map.put(acc, :port, port)
        end

      _ ->
        acc
    end
  end

  # The suffix becomes part of an atom and a node name; anything but the
  # characters mob_dev emits means the file isn't what it wrote.
  defp valid_suffix?(suffix) do
    suffix != "" and
      suffix
      |> String.to_charlist()
      |> Enum.all?(&(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in [?_, ?-]))
  end

  defp parse_port(raw) when raw in [nil, ""], do: nil

  defp parse_port(raw) do
    case Integer.parse(raw) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _ -> nil
    end
  end

  @doc false
  # Precedence: a custom `:cookie` from the app, the managed cookie mob_dev
  # wrote, then a random one. Returns the source alongside, for the log line;
  # the value itself is never logged.
  @spec android_cookie(keyword()) :: {:app | :managed | :ephemeral, atom()}
  def android_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      cookie when is_atom(cookie) and cookie not in [nil, @legacy_cookie] ->
        {:app, cookie}

      _ ->
        case managed_cookie() do
          nil -> {:ephemeral, random_cookie()}
          cookie -> {:managed, cookie}
        end
    end
  end

  defp managed_cookie do
    with dir when dir not in [nil, ""] <- System.get_env("MOB_BEAMS_DIR"),
         {:ok, raw} <- File.read(Path.join(dir, @cookie_file)),
         cookie = String.trim(raw),
         true <- valid_cookie?(cookie) do
      String.to_atom(cookie)
    else
      _ -> nil
    end
  end

  # mob_dev writes 32 random bytes as lowercase hex; anything else is not its file.
  defp valid_cookie?(cookie) do
    byte_size(cookie) == 64 and
      cookie |> String.to_charlist() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))
  end

  defp random_cookie do
    32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower) |> String.to_atom()
  end

  defp cookie_log(:app, _opts), do: "using the app's custom distribution cookie"
  defp cookie_log(:managed, _opts), do: "using the mob_dev-managed distribution cookie"

  defp cookie_log(:ephemeral, opts) do
    legacy =
      if Keyword.get(opts, :cookie) == @legacy_cookie,
        do: "ignoring the public :mob_secret cookie; ",
        else: ""

    legacy <>
      "no managed cookie in $MOB_BEAMS_DIR/#{@cookie_file}, using a random one " <>
      "(run mix mob.connect to restart with the managed cookie)"
  end

  @doc """
  Stop Erlang distribution and shut down EPMD.

  Disconnects all connected nodes, stops the distribution listener, and
  terminates the local EPMD daemon if one was started by this node.

  Intended for use after an OTA update session or when forming a `Mob.Cluster`
  connection that should not persist. The app continues running normally after
  calling `stop/0` — only remote connectivity is removed.

  Returns `:ok` whether or not distribution was running.

      # OTA update session
      Mob.Dist.ensure_started(node: :"my_app@127.0.0.1", cookie: session_cookie)
      Node.connect(update_server_node)
      # ... receive BEAMs ...
      Mob.Dist.stop()

      # Mob.Cluster — rotate cookie between sessions
      Node.set_cookie(new_session_cookie)   # no restart needed
  """
  @spec stop() :: :ok
  def stop do
    if Node.alive?() do
      Enum.each(Node.list(), &Node.disconnect/1)
      :net_kernel.stop()
    end

    :ok
  end

  @doc false
  # Without `inet_dist_use_interface` the listener binds every interface, so
  # anyone on the phone's WiFi could reach it. Loopback is all the Mac needs:
  # `adb forward` connects to the device's own 127.0.0.1.
  @spec start_distribution(node(), atom(), pos_integer()) :: {:ok, pid()} | {:error, term()}
  def start_distribution(node, cookie, dist_port) do
    # Prevent OTP from spawning a local epmd daemon — the Mac's EPMD is available
    # via the ADB reverse tunnel and we must not fight it for port 4369.
    :application.set_env(:kernel, :start_epmd, false)
    # Pin the dist port so mob_dev knows which port to adb-forward.
    :application.set_env(:kernel, :inet_dist_listen_min, dist_port)
    :application.set_env(:kernel, :inet_dist_listen_max, dist_port)
    :application.set_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})

    with {:ok, _} = started <- Node.start(node, :longnames) do
      Node.set_cookie(cookie)
      started
    end
  end

  defp start_after(node, cookie, delay, dist_port) do
    Process.sleep(delay)
    # Wait for EPMD on port 4369 before starting distribution.
    #
    # When `mix mob.connect` is running, it sets up `adb reverse tcp:4369 tcp:4369`
    # which forwards device:4369 → Mac EPMD. We must not spawn a local epmd (which
    # would also try to bind 4369), so we set start_epmd: false and wait for the
    # Mac's EPMD to be reachable via the ADB tunnel.
    #
    # Without the tunnel (standalone launch), EPMD will never appear on 4369 and
    # we skip distribution entirely — the app runs fine, just not debuggable remotely.
    :mob_nif.log("Mob.Dist: waiting for EPMD (adb reverse tcp:4369 tcp:4369)...")

    case wait_for_epmd(10_000) do
      :ready ->
        :mob_nif.log("Mob.Dist: EPMD reachable, starting dist")
        # OTP auth tries to write HOME/.config/erlang/.erlang.cookie — ensure the dir exists.
        home = System.get_env("HOME") || "/data/data/com.mob.demo/files"
        File.mkdir_p("#{home}/.config/erlang")
        result = start_distribution(node, cookie, dist_port)
        :mob_nif.log("Mob.Dist: result=#{inspect(result)}")

        if match?({:ok, _}, result), do: :mob_nif.log("Mob.Dist: distribution started")

      :timeout ->
        :mob_nif.log(
          "Mob.Dist: no EPMD on port 4369 after 10s -- skipping dist (run mix mob.connect to enable)"
        )
    end
  end

  # Poll port 4369 until the ADB-tunnelled Mac EPMD responds or we time out.
  defp wait_for_epmd(remaining_ms) when remaining_ms <= 0, do: :timeout

  defp wait_for_epmd(remaining_ms) do
    case :gen_tcp.connect({127, 0, 0, 1}, 4369, [], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ready

      {:error, _} ->
        Process.sleep(500)
        wait_for_epmd(remaining_ms - 700)
    end
  end
end
