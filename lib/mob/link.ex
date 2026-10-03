defmodule Mob.Link do
  @moduledoc """
  The `{:link, link}` message a screen receives when the app is opened by a
  URL: a link tapped in another app, a QR code read by the camera or a scanner
  app, `adb shell am start -a android.intent.action.VIEW -d 'myapp://…'`,
  `xcrun simctl openurl booted 'myapp://…'`.

      def handle_info({:link, %{url: url}}, socket) do
        case URI.parse(url) do
          %URI{scheme: "myapp", host: "thread", query: query} when is_binary(query) ->
            params = URI.decode_query(query)
            {:noreply, Mob.Socket.push_screen(socket, MyApp.ThreadScreen, params)}

          _ ->
            {:noreply, socket}
        end
      end

  Any app on the device can open one, with anything in it. Parse it and check
  what it asks for before acting on it.

  ## Fields

    * `:url` — the URL as the platform handed it over.
    * `:source` — `:launch` when it opened the app, or arrived while the app
      was starting: it was held until the root screen had mounted.
      `:running` when the app was already running.

  ## Where it is delivered

  To the process registered with `register/1` while it is alive, otherwise to
  the screen currently showing. A link that launches the app arrives once the
  root screen has mounted, exactly once. A screen that defines its own
  `handle_info/2` clauses needs one for `{:link, _}` (or a catch-all) to
  receive links without crashing.

  ## Which links open the app

  A custom scheme is declared at build time: `config :mob_dev, url_schemes:
  ["myapp"]` in `mob.exs` makes the native build (mob_dev 0.7.12 or later) add
  an intent filter to the Android main activity and a `CFBundleURLTypes` entry
  to the iOS bundle. A change needs a native rebuild.

  Native code hands each URL to mob with `mob_deliver_link(const char *url)`
  (`mob_beam.h`, both platforms): the generated Android `MainActivity`
  forwards `ACTION_VIEW` intents through `MobBridge.nativeDeliverLink`, and the
  iOS `SceneDelegate` forwards its URL contexts. An app whose native files were
  generated before mob_new 0.6.4 adds those calls itself; see "Deep links" in
  the device capabilities guide. Like notifications, every link passes through
  the `:mob_screen` router, which keeps the one that launched the app until
  the root screen has mounted; see
  `decisions/2026-10-03-deep-link-delivery.md`.
  """

  @key {__MODULE__, :handler}

  @type t :: %{url: String.t(), source: :launch | :running}

  @doc """
  Sends links to `pid` rather than to the screen showing, while `pid` is
  alive. A later call replaces the registration.

  It can be called before the root screen starts (in the app's `on_start/0`,
  say), so the link that launched the app goes to `pid` too.
  """
  @spec register(pid()) :: :ok
  def register(pid \\ self()) when is_pid(pid) and node(pid) == node() do
    # A local pid is an immediate term, so replacing it does not make
    # :persistent_term scan every process; the check skips even the write when
    # a screen registers itself again on every mount.
    if :persistent_term.get(@key, nil) != pid, do: :persistent_term.put(@key, pid)
    :ok
  end

  @doc """
  Drops the registration: links go to the screen showing again.
  """
  @spec unregister() :: :ok
  def unregister do
    :persistent_term.erase(@key)
    :ok
  end

  @doc """
  The registered pid, alive or not, or `nil`.
  """
  @spec registered() :: pid() | nil
  def registered, do: :persistent_term.get(@key, nil)
end
