defmodule Mob.Dist do
  @moduledoc """
  Platform-aware Erlang distribution startup.

  On iOS, distribution is started at BEAM launch via flags in mob_beam.m
  (`-name mob_demo@127.0.0.1`), so nothing extra is needed here.

  On Android, starting distribution at BEAM launch races with Android's hwui
  thread pool initialization (~125ms window), corrupting an internal mutex and
  causing a SIGABRT. The fix is to defer `Node.start/2` until after the UI has
  fully settled.

  ## Usage (in your app's start/0)

      Mob.Dist.ensure_started(node: :"mob_demo@127.0.0.1", cookie: :mob_secret)

  Options:
  - `:node`   — node name atom, e.g. `:"mob_demo@127.0.0.1"` (required on Android)
  - `:cookie` — cookie atom, e.g. `:mob_secret` (required on Android)
  - `:delay`  — ms to wait before starting dist on Android (default: 3_000)
  """

  @default_delay 3_000

  @doc """
  Ensure Erlang distribution is running for the current platform.

  - iOS: no-op (dist already started via BEAM args in mob_beam.m).
  - Android: spawns a process that sleeps for `:delay` ms then calls
    `Node.start/2` + `Node.set_cookie/1`. Pins the dist port to `:dist_port`
    (default 9100) so `dev_connect.sh` knows which port to forward.

  Options:
  - `:node`      — node name atom (required on Android)
  - `:cookie`    — cookie atom (required on Android)
  - `:delay`     — ms to wait before starting dist (default: 3_000)
  - `:dist_port` — Erlang dist listen port (default: 9100)
  """
  @spec ensure_started(keyword()) :: :ok
  def ensure_started(opts \\ []) do
    case :mob_nif.platform() do
      :ios ->
        :ok

      :android ->
        node      = Keyword.fetch!(opts, :node)
        cookie    = Keyword.fetch!(opts, :cookie)
        delay     = Keyword.get(opts, :delay, @default_delay)
        dist_port = Keyword.get(opts, :dist_port, 9100)
        spawn(fn -> start_after(node, cookie, delay, dist_port) end)
        :ok
    end
  end

  defp start_after(node, cookie, delay, dist_port) do
    Process.sleep(delay)
    :mob_nif.log(~c"Mob.Dist: starting dist")
    # OTP auth tries to write HOME/.config/erlang/.erlang.cookie — ensure the dir exists.
    home = System.get_env("HOME") || "/data/data/com.mob.demo/files"
    File.mkdir_p("#{home}/.config/erlang")
    # Pin the dist port so dev_connect.sh knows which port to adb-forward.
    :application.set_env(:kernel, :inet_dist_listen_min, dist_port)
    :application.set_env(:kernel, :inet_dist_listen_max, dist_port)
    result = Node.start(node, :longnames)
    :mob_nif.log(:lists.flatten(:io_lib.format(~c"Mob.Dist: result=~w", [result])))
    case result do
      {:ok, _} ->
        Node.set_cookie(cookie)
        :mob_nif.log(~c"Mob.Dist: distribution started")
      _ -> :ok
    end
  end
end
