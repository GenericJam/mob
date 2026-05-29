defmodule Mob.Test do
  @moduledoc """
  Remote inspection and interaction helpers for connected Mob apps.

  All functions accept a `node` atom and operate on the running screen via
  Erlang distribution. Connect first with `mix mob.connect`, then use these
  from IEx or from an agent via `:rpc.call/4`.

  ## Quick reference

      node = :"my_app_ios@127.0.0.1"

      # Inspection
      Mob.Test.screen(node)               #=> MyApp.HomeScreen
      Mob.Test.assigns(node)              #=> %{count: 3, ...}
      Mob.Test.tree(node)                 #=> %{type: :column, ...}
      Mob.Test.find(node, "Save")         #=> [{[0, 2], %{...}}]
      Mob.Test.inspect(node)              #=> %{screen: ..., assigns: ..., tree: ...}

      # Interaction
      Mob.Test.tap(node, :increment)      # tap a button by tag
      Mob.Test.back(node)                 # system back gesture
      Mob.Test.pop(node)                  # pop to previous screen (synchronous)
      Mob.Test.navigate(node, MyApp.DetailScreen, %{id: 42})
      Mob.Test.pop_to(node, MyApp.HomeScreen)
      Mob.Test.pop_to_root(node)

      # Lists
      Mob.Test.select(node, :my_list, 0)  # select first row

      # Visual capture + scroll (in-process, over dist — no adb/xcrun)
      {:ok, png} = Mob.Test.screenshot(node)
      Mob.Test.scroll_info(node, "feed")            # offset/content/viewport
      Mob.Test.scroll_to(node, "feed", :bottom)
      Mob.Test.screenshot_tour(node, "feed")        # page top→bottom, capture each

      # Element positions without a screenshot (elements need an :id)
      Mob.Test.element_frames(node)                 # %{id => {x, y, w, h}}
      Mob.Test.frame(node, "save")                  # {x, y, w, h}
      Mob.Test.tap_id(node, "save")                 # drive by id at real coords

      # Device API simulation
      Mob.Test.send_message(node, {:permission, :camera, :granted})
      Mob.Test.send_message(node, {:camera, :photo, %{path: "/tmp/photo.jpg", width: 1920, height: 1080}})
      Mob.Test.send_message(node, {:location, %{lat: 43.65, lon: -79.38, accuracy: 10.0, altitude: 80.0}})
      Mob.Test.send_message(node, {:notification, %{id: "n1", title: "Hi", body: "Hey", data: %{}, source: :push}})

  ## Tap vs send_message

  `tap/2` is for UI interactions that go through `handle_event/3` via the native
  tap registry. `send_message/2` delivers any term directly to `handle_info/2`.
  Use `send_message/2` to simulate async results from device APIs (camera, location,
  notifications, etc.) without having to trigger the actual hardware.

  ## Synchronous vs fire-and-forget

  Navigation functions (`pop`, `navigate`, `pop_to`, `pop_to_root`) are synchronous —
  they block until the navigation and re-render complete. This makes them safe to
  follow immediately with `screen/1` or `assigns/1` to verify the result.

  `back/1` and `send_message/2` are fire-and-forget (they send a message to the
  screen process and return immediately). Use `:sys.get_state/1` as a sync point
  if you need to wait before reading state:

      Mob.Test.send_message(node, {:permission, :camera, :granted})
      :rpc.call(node, :sys, :get_state, [:mob_screen])  # flush mailbox
      Mob.Test.assigns(node)

  ## Two layers of inspection: render tree vs native UI

  `Mob.Test` exposes two complementary views of what the app is showing:

  | API                           | Source                              | When to use |
  |-------------------------------|-------------------------------------|-------------|
  | `tree/1`, `find/2`            | Mob render tree (logical components) | Mob apps you control. Fast, exact, has `on_tap` tags, no AX activation needed. |
  | `view_tree/1`, `find_view/2`  | Native view hierarchy via NIF       | Native pixel frames; works for any app on iOS UIKit; shallow on SwiftUI/Compose. |
  | `ui_tree/1`                   | OS accessibility tree               | What sighted users read; works on any app *if* AX is active (iOS: VoiceOver). Strict superset of `view_tree` for UIKit; the only path to semantics inside SwiftUI/Compose. |

  Choose render tree first if your app is Mob-rendered. Reach for `view_tree`
  when you want native frames or geometry. Reach for `ui_tree` when you need
  to inspect non-Mob content (alerts, system overlays, third-party SDK UI),
  or to verify the *rendered* state matches the logical render.

  ## Driving controls beyond plain taps

  - **Buttons / nav items** — `tap/2` (by tag, fastest), or
    `mob_nif:tap/1` (by accessibility label), or `tap_xy/3` (by coordinate).
  - **Sliders, steppers, pickers** — `adjust_slider/4` and the underlying
    `ax_action/3` / `ax_action_at_xy/4` use `accessibilityIncrement` /
    `accessibilityDecrement`. Synthetic drag gestures don't fire SwiftUI's
    `DragGesture` reliably; AX actions do.
  - **Switches / toggles** — `toggle/2` finds the switch by nearby label and
    activates it via the AX path (sends `accessibilityActivate`).
  - **Modals / alerts / sheets** — `dismiss_alert/2` uses
    `accessibilityActivate` on the named button; `ax_action/3` with
    `:escape` sends `accessibilityPerformEscape`.
  - **Scroll views** — `ax_action/3` with `:scroll_up`/`:scroll_down`/
    `:scroll_left`/`:scroll_right` sends `accessibilityScroll:`.
  - **System back** — `back/1` (Mob screens, framework-level) or — for
    sidecar mode against arbitrary apps — synthetic edge-pan via `swipe/5`
    from `x=0`, but iOS owns that gesture above the app process and the
    synthetic pan won't fire. Use `back/1` for Mob, document the limitation
    for sidecar.

  ## Platform support matrix

  | Helper                       | iOS sim       | iOS device    | Android         |
  |------------------------------|---------------|---------------|-----------------|
  | `screen/1`, `assigns/1`      | ✅            | ✅            | ✅              |
  | `tap/2` (by tag)             | ✅            | ✅            | ✅              |
  | `back/1`, `pop/1`, `navigate`| ✅            | ✅            | ✅              |
  | `send_message/2`             | ✅            | ✅            | ✅              |
  | `screen_info/1`              | ✅            | ✅            | ✅              |
  | `view_tree/1`                | ✅ (shallow†) | ✅ (shallow†) | ✅ (root only‡) |
  | `find_view/2`                | ✅            | ✅            | ✅              |
  | `ui_tree/1` (legacy AX)      | ⚠️ AX active§ | ⚠️ AX active§ | ❌ not_loaded   |
  | `ax_action/3`                | ⚠️ AX active§ | ⚠️ AX active§ | ❌ not_supported |
  | `ax_action_at_xy/4`          | ⚠️ AX active§ | ⚠️ AX active§ | ❌ not_supported |
  | `toggle/2`                   | ⚠️ AX active§ | ⚠️ AX active§ | ❌ ui_tree_unavailable |
  | `dismiss_alert/2`            | ⚠️ AX active§ | ⚠️ AX active§ | ❌ ui_tree_unavailable |
  | `adjust_slider/4`            | ⚠️ AX active§ | ⚠️ AX active§ | ❌ ui_tree_unavailable |
  | `tap_xy/3`                   | ✅ (AX path)  | ✅ (HID inj.) | n/a             |
  | `swipe/5`                    | ⚠️ scroll only| ✅ (HID inj.) | n/a             |

  - **†** SwiftUI doesn't expose its content as separate UIView instances —
    `view_tree` reaches the SwiftUI hosting view's container and stops.
    For semantic content on Mob screens use `tree/1` (render tree); for any
    other SwiftUI-based content use `ui_tree/1`.
  - **‡** Android's Mob renderer is Compose. The View walk stops at the
    `AndroidComposeView` host. The eventual fix is `Modifier.onGloballyPositioned`
    in Mob's components writing to a registry the NIF reads (planned).
    See `issues.md` #11.
  - **§** "AX active" means an iOS accessibility client is asking for the
    AX tree so SwiftUI materializes it. Today: VoiceOver toggle. Production:
    `XCAXClient_iOS` activation, debug-only — see WireTap stretch goals in
    `future_developments.md`.

  Helpers that depend on AX return clear error tuples on Android instead of
  raising. Callers should match on `{:error, :not_supported_on_android}` and
  `{:error, :ui_tree_unavailable}` and either skip or fall back to
  `send_message/2` for state mutations.

  ## Known limitations affecting AX automation

  Even on iOS with AX active, three Mob component defects keep the natural
  paths from working today. Workarounds in each helper's docstring:

  - **Slider** — `accessibilityIncrement`/`Decrement` are no-ops because
    Mob's iOS Slider doesn't attach `.accessibilityAdjustableAction`.
    See `issues.md` #7.
  - **Toggle** — the `label:` prop doesn't reach the AX tree; `toggle/2`
    can't find the switch by label name. Use `ax_action_at_xy/4` with
    coordinates for now. See `issues.md` #8.
  - **Alert OK button** — `accessibilityActivate` on the AX-tree button
    doesn't fire the underlying `UIAlertAction`. Use Mob `Alert` with
    `action:` atoms and `send_message/2` to dismiss programmatically.
    See `issues.md` #9.

  System-level gestures iOS owns *above* the app process (edge-pan back,
  swipe-up app switcher, pull-down notification center) are out of reach
  for in-process synthetic touches on physical devices. Use `back/1` for
  Mob screens; for sidecar mode against arbitrary apps, document the
  limitation rather than promising the gesture.
  """

  # ── Inspection ────────────────────────────────────────────────────────────────

  @doc "Return the current screen module."
  @spec screen(node()) :: module()
  def screen(node), do: rpc(node, :get_current_module)

  @doc "Return the current screen's assigns map."
  @spec assigns(node()) :: map()
  def assigns(node), do: rpc(node, :get_socket).assigns

  @doc """
  Return a map with `:screen`, `:assigns`, `:nav_history`, and `:tree`
  (the raw render tree from calling `render/1` on the current screen).
  """
  @spec inspect(node()) :: map()
  def inspect(node), do: rpc(node, :inspect)

  @doc "Return the current rendered tree (calls render/1 on the live assigns)."
  @spec tree(node()) :: map()
  def tree(node), do: rpc(node, :inspect).tree

  @doc """
  Find all nodes in the current tree whose text contains `substring`.
  Returns a list of `{path, node}` tuples where `path` is a list of
  indices from the root.

      Mob.Test.find(node, "Device APIs")
      #=> [{[0, 1, 8], %{"type" => "button", "props" => %{"text" => "Device APIs →", ...}}}]
  """
  @spec find(node(), String.t()) :: [{list(), map()}]
  def find(node, substring) do
    search(tree(node), substring, [])
  end

  # ── Tap ───────────────────────────────────────────────────────────────────────

  @doc """
  Send a tap event to the current screen by tag atom.

  The tag comes from `on_tap: {self(), :tag_atom}` in the screen's `render/1`.
  Check the screen's render function to find available tags.

  Fire-and-forget — does not wait for the screen to finish processing.

      Mob.Test.tap(node, :save)
      Mob.Test.tap(node, :open_detail)
  """
  @spec tap(node(), atom()) :: :ok
  def tap(node, tag) do
    :rpc.call(node, Process, :send, [:mob_screen, {:tap, tag}, []])
    :ok
  end

  # ── System gestures ───────────────────────────────────────────────────────────

  @doc """
  Simulate the system back gesture (Android hardware back / iOS edge-pan).

  Fire-and-forget. The framework pops the navigation stack; if already at the
  root, it exits the app. Prefer `pop/1` when you need to know that navigation
  has finished before reading state.
  """
  @spec back(node()) :: :ok
  def back(node) do
    :rpc.call(node, Process, :send, [:mob_screen, {:mob, :back}, []])
    :ok
  end

  # ── Navigation (synchronous) ──────────────────────────────────────────────────

  @doc """
  Pop the current screen and return to the previous one. Synchronous.

  Returns `:ok` once the navigation and re-render are complete, so it is safe
  to call `screen/1` or `assigns/1` immediately after.

  No-op (returns `:ok`) if already at the root of the stack.
  """
  @spec pop(node()) :: :ok
  def pop(node), do: nav(node, {:pop})

  @doc """
  Push a new screen onto the navigation stack. Synchronous.

  `dest` is a screen module or a registered name atom (from `navigation/1`).
  `params` are passed to the new screen's `mount/3`.

      Mob.Test.navigate(node, MyApp.DetailScreen, %{id: 42})
      Mob.Test.navigate(node, :detail, %{id: 42})
      Mob.Test.navigate(node, MyApp.SettingsScreen)
  """
  @spec navigate(node(), module() | atom(), map()) :: :ok
  def navigate(node, dest, params \\ %{}), do: nav(node, {:push, dest, params})

  @doc """
  Pop the stack until `dest` is at the top. Synchronous.

  `dest` is a screen module or registered name atom. No-op if not in history.
  """
  @spec pop_to(node(), module() | atom()) :: :ok
  def pop_to(node, dest), do: nav(node, {:pop_to, dest})

  @doc """
  Pop all screens back to the root of the current stack. Synchronous.
  """
  @spec pop_to_root(node()) :: :ok
  def pop_to_root(node), do: nav(node, {:pop_to_root})

  @doc """
  Replace the entire navigation stack with a new root screen. Synchronous.

  Use this to simulate auth transitions (e.g. login → home with no back button).
  """
  @spec reset_to(node(), module() | atom(), map()) :: :ok
  def reset_to(node, dest, params \\ %{}), do: nav(node, {:reset, dest, params})

  # ── Lists ─────────────────────────────────────────────────────────────────────

  @doc """
  Select a row in a `:list` component by index.

  `list_id` must match the `:id` prop on the `type: :list` node. `index` is
  zero-based. Delivers `{:select, list_id, index}` to `handle_info/2`.

  Fire-and-forget.

      Mob.Test.select(node, :my_list, 0)   # first row
  """
  @spec select(node(), atom(), non_neg_integer()) :: :ok
  def select(node, list_id, index) when is_atom(list_id) and is_integer(index) do
    :rpc.call(node, Process, :send, [:mob_screen, {:select, list_id, index}, []])
    :ok
  end

  # ── send_message ──────────────────────────────────────────────────────────────

  @doc """
  Send an arbitrary message to the screen's `handle_info/2`. Fire-and-forget.

  Use this to simulate results from device APIs without triggering real hardware:

      # Permissions
      Mob.Test.send_message(node, {:permission, :camera, :granted})
      Mob.Test.send_message(node, {:permission, :notifications, :denied})

      # Camera
      Mob.Test.send_message(node, {:camera, :photo, %{path: "/tmp/photo.jpg", width: 1920, height: 1080}})
      Mob.Test.send_message(node, {:camera, :cancelled})

      # Location
      Mob.Test.send_message(node, {:location, %{lat: 43.6532, lon: -79.3832, accuracy: 10.0, altitude: 80.0}})
      Mob.Test.send_message(node, {:location, :error, :denied})

      # Photos / Files
      Mob.Test.send_message(node, {:photos, :picked, [%{path: "/tmp/photo.jpg", width: 800, height: 600}]})
      Mob.Test.send_message(node, {:files, :picked, [%{path: "/tmp/doc.pdf", name: "doc.pdf", size: 4096}]})

      # Audio / Motion / Scanner
      Mob.Test.send_message(node, {:audio, :recorded, %{path: "/tmp/audio.aac", duration: 12}})
      Mob.Test.send_message(node, {:motion, %{ax: 0.1, ay: 9.8, az: 0.0, gx: 0.0, gy: 0.0, gz: 0.0}})
      Mob.Test.send_message(node, {:scan, :result, %{type: :qr, value: "https://example.com"}})

      # Notifications
      Mob.Test.send_message(node, {:notification, %{id: "n1", title: "Hi", body: "Hello", data: %{}, source: :push}})
      Mob.Test.send_message(node, {:push_token, :ios, "abc123def456"})

      # Biometric
      Mob.Test.send_message(node, {:biometric, :success})
      Mob.Test.send_message(node, {:biometric, :failure, :user_cancel})

      # Custom
      Mob.Test.send_message(node, {:my_event, %{key: "value"}})
  """
  @spec send_message(node(), term()) :: :ok
  def send_message(node, message) do
    :rpc.call(node, Process, :send, [:mob_screen, message, []])
    :ok
  end

  # ── Native UI — unmodified app test harness ─────────────────────────────────
  #
  # These functions drive the native UI of any app — not just Mob-rendered ones.
  # They call mob_nif directly via RPC and do not require a mob screen process.

  @doc """
  Return the live accessibility tree from the running native app.

  Each element is a tuple: `{type, label, value, {x, y, w, h}}`

      Mob.Test.ui_tree(node)
      #=> [{:button, "Increment", "", {164.0, 400.0, 54.0, 54.0}}, ...]
  """
  @spec ui_tree(node()) :: list()
  def ui_tree(node) do
    :rpc.call(node, :mob_nif, :ui_tree, [])
  end

  @doc """
  Return the live UI tree as a nested map, walking native views directly.

  Unlike `ui_tree/1` (which uses the accessibility subsystem and requires
  VoiceOver activation on iOS), this walks UIView/View hierarchies directly:
  no AX activation needed.

  ## Coverage caveat

  - **UIKit apps (sidecar mode)**: full UIView hierarchy with labels and frames.
  - **SwiftUI apps (current Mob)**: shallow — SwiftUI doesn't expose its content
    as separate UIView instances under the hosting view. You'll see containers
    and scroll views but not individual buttons/text. For Mob apps, prefer
    `Mob.Test.tree/1` (the logical render tree, which has all the semantic info)
    or `Mob.Test.ui_tree/1` (AX walk, requires VoiceOver activation).
  - **Android (planned)**: a registry populated via `onGloballyPositioned` in
    Mob's Compose components — see `future_developments.md` "WireTap" section.

  Returns a nested map:

      %{
        type: :root, label: nil, value: nil,
        frame: {0.0, 0.0, 393.0, 852.0},
        children: [
          %{type: :window, ..., children: [
            %{type: :scroll, ..., children: [
              %{type: :button, label: "Roll Dice",
                frame: {24.0, 416.0, 327.0, 53.5}, children: []}
            ]}
          ]}
        ]
      }

  On Android, the JSON returned by `mob_nif:ui_view_tree/0` is decoded here.
  """
  @spec view_tree(node()) :: map() | {:error, term()}
  def view_tree(node) do
    case :rpc.call(node, :mob_nif, :ui_view_tree, []) do
      bin when is_binary(bin) -> :json.decode(bin) |> normalize_tree()
      %{} = m -> m
      other -> other
    end
  end

  # JSON decode produces string keys; the iOS NIF returns atom keys directly.
  # Normalize to atom keys so the API is uniform across platforms.
  defp normalize_tree(%{"type" => _} = node) do
    %{
      type: normalize_atom(node["type"]),
      label: node["label"],
      value: node["value"],
      frame:
        case node["frame"] do
          [x, y, w, h] -> {x * 1.0, y * 1.0, w * 1.0, h * 1.0}
          other -> other
        end,
      children: Enum.map(node["children"] || [], &normalize_tree/1)
    }
  end

  defp normalize_tree(other), do: other

  defp normalize_atom(s) when is_binary(s), do: String.to_atom(s)
  defp normalize_atom(a) when is_atom(a), do: a

  @doc """
  Return the view tree flattened to a list of `{path, node}` tuples.

  `path` is the list of child indices from the root — e.g. `[0, 2, 1]` is
  "the second child of the third child of the first child of the root."

  Useful for filter/find — see `find_view/2`.

      Mob.Test.view_tree_flat(node)
      #=> [
      #     {[], %{type: :root, ...}},
      #     {[0], %{type: :window, ...}},
      #     {[0, 0], %{type: :scroll, ...}},
      #     ...
      #   ]
  """
  @spec view_tree_flat(node()) :: [{[non_neg_integer()], map()}]
  def view_tree_flat(node) when is_atom(node), do: flatten_tree(view_tree(node))

  @doc """
  Flatten an already-fetched view tree. Pure function — useful for tests
  and for inspecting a captured tree without re-fetching.

      tree = Mob.Test.view_tree(node)
      flat = Mob.Test.flatten_tree(tree)
  """
  @spec flatten_tree(map()) :: [{[non_neg_integer()], map()}]
  def flatten_tree(%{} = tree), do: do_flatten(tree, []) |> Enum.reverse()
  def flatten_tree(other), do: other

  defp do_flatten(%{children: children} = node, path) do
    self_entry = [{path, Map.delete(node, :children)}]

    children
    |> Enum.with_index()
    |> Enum.reduce(self_entry, fn {child, i}, acc ->
      do_flatten(child, path ++ [i]) ++ acc
    end)
  end

  defp do_flatten(other, path), do: [{path, other}]

  @doc """
  Find nodes in the view tree whose label or value contains `text`.

  Returns `[{path, node}]` for each match. Faster and more accurate than
  `find_native/2` (no AX dependency, sees all views).

      Mob.Test.find_view(node, "Roll Dice")
      #=> [{[0, 0, 0, 4], %{type: :button, label: "Roll Dice", ...}}]
  """
  @spec find_view(node(), String.t()) :: [{[non_neg_integer()], map()}]
  def find_view(node, text) do
    node
    |> view_tree_flat()
    |> Enum.filter(fn {_path, %{} = n} ->
      String.contains?(to_string(n[:label] || ""), text) or
        String.contains?(to_string(n[:value] || ""), text)
    end)
  end

  @doc """
  Invoke an accessibility action on the first AX element matching `match`.

  ## Platform support

  - **iOS**: works once AX is active (today: VoiceOver on; future:
    `XCAXClient_iOS` activation, see `future_developments.md`).
  - **Android**: returns `{:error, :not_supported_on_android}`. The Compose
    semantics walker is queued under WireTap (issues.md #11).

  Used for controls where synthetic touches don't reach the gesture recognizer
  (sliders, scrolls, modal dismissal).

  `match` is a string searched in both label and value. `action` is one of:
  `:increment`, `:decrement`, `:activate`, `:escape`, `:scroll_up`,
  `:scroll_down`, `:scroll_left`, `:scroll_right`.

      Mob.Test.ax_action(node, "Volume", :decrement)
      Mob.Test.ax_action(node, "Cancel", :activate)
  """
  @spec ax_action(node(), String.t(), atom()) :: :ok | {:error, atom()}
  def ax_action(node, match, action) do
    :rpc.call(node, :mob_nif, :ax_action, [match, action])
  end

  @doc """
  Invoke an AX action on whatever element occupies the given screen coordinates.

  Useful when label/value substring matching is ambiguous (e.g. multiple
  sliders that all read "50%", a toggle whose accessibility label is empty).
  Caller picks coordinates from `ui_tree/1` and points at the exact element.

      Mob.Test.ax_action_at_xy(node, 187.0, 296.0, :increment)

  ## Platform support

  - **iOS**: works once AX is active (VoiceOver on, today).
  - **Android**: returns `{:error, :not_supported_on_android}` — see
    `ax_action/3`.
  """
  @spec ax_action_at_xy(node(), number(), number(), atom()) :: :ok | {:error, atom()}
  def ax_action_at_xy(node, x, y, action) do
    :rpc.call(node, :mob_nif, :ax_action_at_xy, [x * 1.0, y * 1.0, action])
  end

  @doc """
  Toggle a switch by a label substring. SwiftUI exposes `Toggle` as a button
  with an empty accessibility label and value `"0"` or `"1"` — so we find the
  Text element matching `label_match`, then activate the next button below it.

      Mob.Test.toggle(node, "Notifications")

  ## Known limitation (issues.md #8)

  Mob's iOS Toggle component does not currently surface its `label:` prop as
  a separate `:text` AX element, so `find_label_y/2` returns
  `{:error, :label_not_found}`. Workaround: use `ax_action_at_xy/4` directly
  with the toggle's frame from `ui_tree/1` (filter for `:button` with value
  `"0"` or `"1"`). Once issue #8 lands, this helper works as documented.
  """
  @spec toggle(node(), String.t()) :: :ok | {:error, atom()}
  def toggle(node, label_match) do
    with {:ok, label_y} <- find_label_y(node, label_match),
         {:ok, {x, y, w, h}} <-
           find_actionable_below(node, label_y, fn {_t, l, v, _f} ->
             is_binary(v) and v in ["0", "1"] and to_string(l) == ""
           end) do
      ax_action_at_xy(node, x + w / 2, y + h / 2, :activate)
    end
  end

  @doc """
  Dismiss a modal/alert overlay by tapping its first button labelled with
  `button_label` (e.g. "OK", "Cancel"). Mirrors what a user does when an
  alert pops up.

      Mob.Test.dismiss_alert(node, "OK")

  ## Known limitation (issues.md #9)

  UIAlertController exposes its buttons twice in the AX tree (visual view +
  action target). Activating the visual view doesn't fire the action. This
  helper currently reports `:ok` while the alert stays on screen. Workaround:
  define alerts with `action: :tag_atom` and dismiss via
  `Mob.Test.send_message(node, {:alert, :tag_atom})`.
  """
  @spec dismiss_alert(node(), String.t()) :: :ok | {:error, atom()}
  def dismiss_alert(node, button_label) do
    with {:ok, tree} <- safe_ui_tree(node) do
      case Enum.find(tree, fn {t, l, _v, _f} ->
             t == :button and to_string(l) == button_label
           end) do
        {_, _, _, {x, y, w, h}} ->
          ax_action_at_xy(node, x + w / 2, y + h / 2, :activate)

        _ ->
          {:error, :button_not_found}
      end
    end
  end

  defp find_label_y(node, match) do
    with {:ok, tree} <- safe_ui_tree(node) do
      case Enum.find(tree, fn {t, l, _v, _f} ->
             t == :text and is_binary(l) and String.contains?(l, match)
           end) do
        {_, _, _, {_x, y, _w, h}} -> {:ok, y + h}
        _ -> {:error, :label_not_found}
      end
    end
  end

  defp find_actionable_below(node, threshold_y, predicate) do
    with {:ok, tree} <- safe_ui_tree(node) do
      case tree
           |> Enum.filter(fn {_t, _l, _v, {_x, y, _w, _h}} -> y >= threshold_y end)
           |> Enum.sort_by(fn {_t, _l, _v, {_x, y, _w, _h}} -> y end)
           |> Enum.find(predicate) do
        {_, _, _, frame} -> {:ok, frame}
        _ -> {:error, :no_actionable_below}
      end
    end
  end

  # Returns {:ok, list} when AX tree is available; {:error, :ui_tree_unavailable}
  # otherwise. Lets callers degrade cleanly on Android (no AX walker yet) and on
  # iOS when VoiceOver isn't activated.
  defp safe_ui_tree(node) do
    case ui_tree(node) do
      list when is_list(list) -> {:ok, list}
      _ -> {:error, :ui_tree_unavailable}
    end
  end

  @doc """
  Step a slider toward a target percentage (0.0..1.0) using accessibility
  increment/decrement actions. Reliable when synthetic-drag won't fire
  (SwiftUI Slider's DragGesture ignores in-process touches on iOS).

  `match` is a substring of the slider's label or value (e.g. `"Volume"`).
  `target` is a fraction 0.0..1.0. `max_steps` caps the increment loop
  (default 30) so a wrong match can't spin forever.

  Returns `{:ok, final_pct}` or `{:error, reason}`.

      Mob.Test.adjust_slider(node, "Volume", 0.30)
      #=> {:ok, 0.30}

  Implementation note: each AX increment/decrement on a SwiftUI slider moves
  by the slider's `.step` value (default 0.10 of the range). The function
  re-reads the slider value after each step to converge.

  ## Known limitation (issues.md #7)

  Mob's iOS Slider component does not currently attach
  `.accessibilityAdjustableAction { … }`, so `accessibilityIncrement` and
  `accessibilityDecrement` are silently dropped by SwiftUI even though the
  NIF returns `:ok`. This helper currently returns `{:error,
  :max_steps_exhausted}` against an unfixed slider. Until issue #7 lands,
  drive sliders via `Mob.Test.send_message(node, {:change, :slider_tag, value})`.
  """
  @spec adjust_slider(node(), String.t(), float(), keyword()) ::
          {:ok, float()} | {:error, term()}
  def adjust_slider(node, match, target, opts \\ []) when target >= 0.0 and target <= 1.0 do
    max_steps = Keyword.get(opts, :max_steps, 30)
    do_adjust_slider(node, match, target, max_steps)
  end

  defp do_adjust_slider(_node, _match, _target, 0), do: {:error, :max_steps_exhausted}

  defp do_adjust_slider(node, match, target, steps_left) do
    with {:ok, label_y} <- find_label_y(node, match),
         {:ok, {x, y, w, h} = frame} <- find_actionable_below(node, label_y, &slider_predicate/1),
         {:ok, pct} <- pct_from_frame(node, frame) do
      cx = x + w / 2
      cy = y + h / 2

      cond do
        abs(pct - target) < 0.05 ->
          {:ok, pct}

        pct < target ->
          ax_action_at_xy(node, cx, cy, :increment)
          Process.sleep(80)
          do_adjust_slider(node, match, target, steps_left - 1)

        true ->
          ax_action_at_xy(node, cx, cy, :decrement)
          Process.sleep(80)
          do_adjust_slider(node, match, target, steps_left - 1)
      end
    end
  end

  defp slider_predicate({_t, _l, v, _f}),
    do: is_binary(v) and String.contains?(v, "%")

  defp slider_predicate(_), do: false

  defp pct_from_frame(node, target_frame) do
    case Enum.find(ui_tree(node), fn {_t, _l, _v, f} -> f == target_frame end) do
      {_, _, value_str, _} when is_binary(value_str) ->
        case value_str |> String.trim_trailing("%") |> Float.parse() do
          {n, _} -> {:ok, n / 100.0}
          :error -> {:error, :unparseable_value}
        end

      _ ->
        {:error, :slider_not_found}
    end
  end

  @doc """
  Return screen geometry in logical units (points on iOS, dp on Android).

      Mob.Test.screen_info(node)
      #=> %{
      #     width: 393.0, height: 852.0, scale: 3.0,
      #     safe_area: %{top: 59.0, bottom: 34.0, left: 0.0, right: 0.0}
      #   }

  `:scale` is the device-pixel ratio (UIScreen.scale on iOS, displayMetrics.density
  on Android). All other values are already in logical units; no further conversion
  needed in the agent.
  """
  @spec screen_info(node()) :: map()
  def screen_info(node) do
    :rpc.call(node, :mob_nif, :screen_info, [])
  end

  @doc """
  Tap at screen coordinates on the native app. On simulator uses accessibility
  activation; on real device synthesises a UITouch via IOHIDEvent.

      Mob.Test.tap_xy(node, 289.7, 518.8)
  """
  @spec tap_xy(node(), number(), number()) :: :ok | {:error, atom()}
  def tap_xy(node, x, y) do
    :rpc.call(node, :mob_nif, :tap_xy, [x * 1.0, y * 1.0])
  end

  @doc """
  Type text into the currently focused text field.

  Tap the field first to give it focus, then call this function.

      Mob.Test.tap_xy(node, 195.0, 300.0)
      Process.sleep(100)
      Mob.Test.type_text(node, "hello@example.com")
  """
  @spec type_text(node(), String.t()) :: :ok | {:error, atom()}
  def type_text(node, text) do
    :rpc.call(node, :mob_nif, :type_text, [text])
  end

  @doc "Delete one character behind the cursor (backspace)."
  @spec delete_backward(node()) :: :ok | {:error, atom()}
  def delete_backward(node) do
    :rpc.call(node, :mob_nif, :delete_backward, [])
  end

  @doc """
  Press a special key on the focused text input.

  Keys: `:return` | `:tab` | `:escape` | `:space`

      Mob.Test.key_press(node, :return)
      Mob.Test.key_press(node, :escape)
  """
  @spec key_press(node(), atom()) :: :ok | {:error, atom()}
  def key_press(node, key) when key in [:return, :tab, :escape, :space] do
    :rpc.call(node, :mob_nif, :key_press, [key])
  end

  @doc "Clear all text in the focused input (select-all + delete)."
  @spec clear_text(node()) :: :ok | {:error, atom()}
  def clear_text(node) do
    :rpc.call(node, :mob_nif, :clear_text, [])
  end

  @doc """
  Long-press at screen coordinates for `duration_ms` milliseconds (default 800ms).

      Mob.Test.long_press_xy(node, 195.0, 400.0)
      Mob.Test.long_press_xy(node, 195.0, 400.0, 1200)
  """
  @spec long_press_xy(node(), number(), number(), non_neg_integer()) :: :ok | {:error, atom()}
  def long_press_xy(node, x, y, duration_ms \\ 800) do
    :rpc.call(node, :mob_nif, :long_press_xy, [x * 1.0, y * 1.0, duration_ms])
  end

  @doc """
  Swipe from (x1, y1) to (x2, y2). Drives UIScrollView contentOffset on
  simulator; synthesises a drag gesture on real device.

      Mob.Test.swipe(node, 195.0, 500.0, 195.0, 100.0)   # scroll down
  """
  @spec swipe(node(), number(), number(), number(), number()) :: :ok | {:error, atom()}
  def swipe(node, x1, y1, x2, y2) do
    :rpc.call(node, :mob_nif, :swipe_xy, [x1 * 1.0, y1 * 1.0, x2 * 1.0, y2 * 1.0])
  end

  @doc """
  Find elements in the native accessibility tree whose label or value contains `text`.

      Mob.Test.find_native(node, "Increment")
      #=> [{:button, "Increment", "", {164.0, 400.0, 54.0, 54.0}}]
  """
  @spec find_native(node(), String.t()) :: list()
  def find_native(node, text) do
    node
    |> ui_tree()
    |> Enum.filter(fn {_type, label, value, _frame} ->
      String.contains?(to_string(label), text) or
        String.contains?(to_string(value), text)
    end)
  end

  @doc """
  Wait until `predicate` returns true when called with the current `ui_tree`,
  polling every `interval_ms` until `timeout_ms` elapses.

      Mob.Test.wait_for(node, fn tree ->
        Enum.any?(tree, fn {_, label, _, _} -> label == "Success" end)
      end)
  """
  @spec wait_for(node(), (list() -> boolean()), keyword()) :: :ok | {:error, :timeout}
  def wait_for(node, predicate, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)
    interval_ms = Keyword.get(opts, :interval_ms, 200)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(node, predicate, deadline, interval_ms)
  end

  @doc """
  Wait until an element whose label or value contains `text` appears in the
  accessibility tree.

      Mob.Test.wait_for_text(node, "Welcome")
      Mob.Test.wait_for_text(node, "Error", timeout_ms: 2000)
  """
  @spec wait_for_text(node(), String.t(), keyword()) :: :ok | {:error, :timeout}
  def wait_for_text(node, text, opts \\ []) do
    wait_for(
      node,
      fn tree ->
        Enum.any?(tree, fn {_type, label, value, _frame} ->
          String.contains?(to_string(label), text) or
            String.contains?(to_string(value), text)
        end)
      end,
      opts
    )
  end

  defp do_wait_for(node, predicate, deadline, interval_ms) do
    tree = ui_tree(node)

    if predicate.(tree) do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        {:error, :timeout}
      else
        Process.sleep(min(interval_ms, remaining))
        do_wait_for(node, predicate, deadline, interval_ms)
      end
    end
  end

  # ── In-process visual capture + scroll control ───────────────────────────────
  #
  # Remote-driving primitives: a connected agent gets pixels and deterministic
  # scroll over Erlang distribution, with no adb / xcrun / idb. These call
  # mob_nif directly via RPC. screenshot returns the raw image bytes, which
  # cross the dist boundary fine (the same path camera frames already take).

  @doc """
  Capture the running app's own window in-process and return the image bytes.

  Returns `{:ok, binary}` (PNG or JPEG) or `{:error, reason}`. The bytes come
  back over Erlang distribution — no `adb screencap` / `xcrun simctl io`, so it
  works against a remote device an agent can only reach over dist.

  Options:

    * `:format` — `:png` (default) or `:jpeg`
    * `:quality` — `0..100`, JPEG only (default `90`)
    * `:scale` — output scale factor (default `1.0`); `0.5` halves resolution

  Captures only the app's own surface, not system layers or other processes.
  Secure text fields (iOS) and `FLAG_SECURE` windows (Android) render blank by
  OS policy. A backgrounded app has no live window, so this fails when the app
  is not foregrounded.

      {:ok, png} = Mob.Test.screenshot(node)
      File.write!("/tmp/shot.png", png)

      {:ok, jpg} = Mob.Test.screenshot(node, format: :jpeg, quality: 60, scale: 0.5)
  """
  @spec screenshot(node(), keyword()) :: {:ok, binary()} | {:error, term()}
  def screenshot(node, opts \\ []) do
    %{format: format, quality: quality, scale: scale} = normalize_screenshot_opts(opts)

    case :rpc.call(node, :mob_nif, :screenshot, [format, quality, scale]) do
      bin when is_binary(bin) -> {:ok, bin}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc false
  # Pure: keyword opts -> the {format, quality, scale} args the NIF expects.
  @spec normalize_screenshot_opts(keyword()) ::
          %{format: :png | :jpeg, quality: 0..100, scale: float()}
  def normalize_screenshot_opts(opts) do
    format =
      case Keyword.get(opts, :format, :png) do
        f when f in [:png, :jpeg] ->
          f

        other ->
          raise ArgumentError,
                "screenshot format must be :png or :jpeg, got: #{Kernel.inspect(other)}"
      end

    quality = opts |> Keyword.get(:quality, 90) |> clamp_int(0, 100)
    scale = opts |> Keyword.get(:scale, 1.0) |> Kernel.*(1.0)
    %{format: format, quality: quality, scale: scale}
  end

  @doc """
  Read a scroll view's current offset and extent, addressed by its `:id` prop
  (the same `:id` you set on a `type: :scroll` or `type: :list` node).

  Returns a map, or `{:error, reason}`:

      %{
        offset:     {x, y},   # current scroll position
        content:    {w, h},   # full scrollable content size
        viewport:   {w, h},   # visible area
        max_offset: {x, y},   # offset at the bottom/right edge
        kind:       :pixel | :index
      }

  `:kind` is `:pixel` for pixel-precise scroll views (iOS `UIScrollView`,
  Android `verticalScroll`). It is `:index` for item-indexed lists (Android
  `LazyColumn`), where the y components count items, not pixels, and `viewport`
  height is the number of visible items. `scroll_to/4` and `screenshot_tour/3`
  work in whichever unit `:kind` reports, so paging stays coherent either way.

      Mob.Test.scroll_info(node, "feed")
      #=> %{offset: {0.0, 0.0}, content: {393.0, 2400.0}, viewport: {393.0, 756.0},
      #     max_offset: {0.0, 1644.0}, kind: :pixel}
  """
  @spec scroll_info(node(), String.t() | atom()) :: map() | {:error, term()}
  def scroll_info(node, id) do
    case :rpc.call(node, :mob_nif, :scroll_info, [to_string(id)]) do
      json when is_binary(json) -> decode_scroll_info(json)
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  # The NIF returns a flat JSON object on both platforms (iOS builds it via
  # NSJSONSerialization, Android via the Kotlin bridge). Decode to the
  # tuple-shaped public map.
  defp decode_scroll_info(json) do
    m = :json.decode(json)

    %{
      offset: {f(m["offset_x"]), f(m["offset_y"])},
      content: {f(m["content_w"]), f(m["content_h"])},
      viewport: {f(m["viewport_w"]), f(m["viewport_h"])},
      max_offset: {f(m["max_x"]), f(m["max_y"])},
      kind: if(m["kind"] == "index", do: :index, else: :pixel)
    }
  end

  defp f(n) when is_number(n), do: n * 1.0
  defp f(_), do: 0.0

  @doc """
  Scroll a view (by `:id`) to a target position. Reads `scroll_info/2` first to
  resolve and clamp the absolute offset, then drives the native scroll view.

  `target`:

    * `{x, y}` — absolute offset (pixels, or item index on an `:index` list)
    * `:top` / `:bottom` — the extremes
    * `{:page, n}` — `n` viewport-heights down from the top (works on both
      `:pixel` and `:index` views)

  Returns `:ok` or `{:error, reason}`.

      Mob.Test.scroll_to(node, "feed", :bottom)
      Mob.Test.scroll_to(node, "feed", {:page, 2})
      Mob.Test.scroll_to(node, "feed", {0.0, 500.0})
  """
  @spec scroll_to(node(), String.t() | atom(), tuple() | atom(), keyword()) ::
          :ok | {:error, term()}
  def scroll_to(node, id, target, _opts \\ []) do
    with %{} = info <- scroll_info(node, id),
         {x, y} <- resolve_scroll_target(target, info) do
      raw_scroll_to(node, id, x, y)
    end
  end

  defp raw_scroll_to(node, id, x, y) do
    case :rpc.call(node, :mob_nif, :scroll_to, [to_string(id), x * 1.0, y * 1.0]) do
      :ok -> :ok
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  @doc false
  # Pure: turn a target (:top | :bottom | {:page, n} | {x, y}) into an absolute
  # {x, y} offset clamped to the scroll view's extent. A "page" is one viewport
  # height in whatever unit `:kind` uses (pixels or item count).
  @spec resolve_scroll_target(tuple() | atom(), map()) :: {float(), float()}
  def resolve_scroll_target(target, %{max_offset: {mx, my}, viewport: {_vw, vh}} = info) do
    {ox, _oy} = Map.get(info, :offset, {0.0, 0.0})

    {x, y} =
      case target do
        :top -> {0.0, 0.0}
        :bottom -> {mx, my}
        {:page, n} when is_number(n) -> {ox, n * vh}
        {x, y} when is_number(x) and is_number(y) -> {x, y}
      end

    {clamp(x * 1.0, 0.0, mx), clamp(y * 1.0, 0.0, my)}
  end

  @doc """
  Walk a scroll view top→bottom, capturing a screenshot at each page. Returns a
  list of `{offset, image_binary}` pairs — the agent's "see the whole long
  screen" path, entirely over dist.

  Options:

    * `:format` / `:quality` / `:scale` — passed through to `screenshot/2`
    * `:overlap` — `0.0..0.9`, fraction of a viewport to overlap between pages
      (default `0.0`)
    * `:settle_ms` — pause after each scroll before capturing (default `150`)

      pages = Mob.Test.screenshot_tour(node, "feed", format: :jpeg, quality: 60)
      for {{_x, y}, bin} <- pages, do: File.write!("/tmp/page_\#{trunc(y)}.jpg", bin)
  """
  @spec screenshot_tour(node(), String.t() | atom(), keyword()) ::
          [{{float(), float()}, binary()}] | {:error, term()}
  def screenshot_tour(node, id, opts \\ []) do
    settle_ms = Keyword.get(opts, :settle_ms, 150)
    shot_opts = Keyword.take(opts, [:format, :quality, :scale])

    with %{} = info <- scroll_info(node, id) do
      info
      |> tour_offsets(opts)
      |> Enum.reduce_while([], fn {x, y} = off, acc ->
        case raw_scroll_to(node, id, x, y) do
          :ok ->
            Process.sleep(settle_ms)

            case screenshot(node, shot_opts) do
              {:ok, bin} -> {:cont, [{off, bin} | acc]}
              {:error, _} = err -> {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:error, _} = err -> err
        list when is_list(list) -> Enum.reverse(list)
      end
    end
  end

  @doc false
  # Pure: the list of {x, y} offsets a top→bottom tour should visit. Steps by
  # one viewport (minus `:overlap`) and always pins a final page to the bottom.
  @spec tour_offsets(map(), keyword()) :: [{float(), float()}]
  def tour_offsets(%{max_offset: {_mx, my}, viewport: {_vw, vh}} = info, opts) do
    {ox, _oy} = Map.get(info, :offset, {0.0, 0.0})
    overlap = opts |> Keyword.get(:overlap, 0.0) |> clamp(0.0, 0.9)
    step = max(vh * (1.0 - overlap), 1.0)

    my
    |> tour_ys(step)
    |> Enum.map(fn y -> {ox, y} end)
  end

  defp tour_ys(my, _step) when my <= 0.0, do: [0.0]

  defp tour_ys(my, step) do
    count = ceil(my / step)

    0..count
    |> Enum.map(fn i -> min(i * step * 1.0, my * 1.0) end)
    |> Enum.uniq()
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
  defp clamp_int(v, lo, hi) when is_integer(v), do: v |> max(lo) |> min(hi)
  defp clamp_int(v, lo, hi), do: v |> trunc() |> max(lo) |> min(hi)

  # ── Element frames (positions without a screenshot) ─────────────────────────

  @doc """
  Return the on-screen frame of every rendered element that carries an `:id`,
  as `%{id => {x, y, w, h}}` in logical units (points on iOS, dp on Android).

  This is the screenshot-free way for an agent to know *where* things are: give
  the elements you want to inspect or drive an `:id`, and their live positions
  come back as a small structured map — no image bytes, no accessibility
  activation. The renderer also sets the `:id` as the element's accessibility
  identifier, so the same tags are visible to external tools (XCUITest, etc.).

  Pairs with `tap_id/2` to drive by id at real coordinates.

      Mob.Test.element_frames(node)
      #=> %{"save" => {24.0, 720.0, 327.0, 48.0}, "row_3" => {0.0, 300.0, 393.0, 56.0}}
  """
  @spec element_frames(node()) ::
          %{optional(String.t()) => {float(), float(), float(), float()}} | {:error, term()}
  def element_frames(node) do
    case :rpc.call(node, :mob_nif, :element_frames, []) do
      json when is_binary(json) -> decode_frames(json)
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp decode_frames(json) do
    json
    |> :json.decode()
    |> Map.new(fn {id, [x, y, w, h]} -> {id, {f(x), f(y), f(w), f(h)}} end)
  end

  @doc """
  Frame `{x, y, w, h}` of the element with `id`, or `nil` if it has no tracked
  position. See `element_frames/1`.

      Mob.Test.frame(node, "save")   #=> {24.0, 720.0, 327.0, 48.0}
  """
  @spec frame(node(), String.t() | atom()) ::
          {float(), float(), float(), float()} | nil | {:error, term()}
  def frame(node, id) do
    case element_frames(node) do
      %{} = frames -> frames[to_string(id)]
      {:error, _} = err -> err
    end
  end

  @doc """
  Tap the element with `id` at the center of its tracked frame — driving by id
  without a screenshot or coordinate guess. The element must carry an `:id`
  (see `element_frames/1`).

      Mob.Test.tap_id(node, "save")
  """
  @spec tap_id(node(), String.t() | atom()) :: :ok | {:error, term()}
  def tap_id(node, id) do
    case frame(node, id) do
      {x, y, w, h} -> tap_xy(node, x + w / 2, y + h / 2)
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  # ── Native UI (requires MCP tools) ───────────────────────────────────────────

  @doc """
  Locate an element and tap it via the simulator's native UI mechanism.

  Requires `idb` (iOS) to be installed. Exercises the full native gesture path
  rather than sending a BEAM message — useful for testing gesture recognizers
  or verifying that the native layer wired up the tap handler correctly.

  Prefer `tap/2` for testing Elixir logic; use `tap_native/1` when you need
  the native path.

      Mob.Test.tap_native("Save")      # by visible text
      Mob.Test.tap_native(:save)       # by accessibility_id (= tag atom name)
  """
  @spec tap_native(atom() | String.t()) :: :ok | {:error, term()}
  def tap_native(tag_or_label) do
    case locate(tag_or_label) do
      {:ok, %{x: x, y: y, width: w, height: h}} ->
        cx = trunc(x + w / 2)
        cy = trunc(y + h / 2)

        case System.cmd("idb", ["ui", "tap", "#{cx}", "#{cy}"]) do
          {_, 0} -> :ok
          {out, code} -> {:error, {code, out}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Locate an element by visible label text or accessibility ID (tag atom name).
  Returns the element's screen frame.

  Requires `idb` (iOS) to be installed.

      Mob.Test.locate(:save)
      #=> {:ok, %{x: 0.0, y: 412.0, width: 402.0, height: 44.0}}

      Mob.Test.locate("Save")
      #=> {:ok, %{x: 0.0, y: 412.0, width: 402.0, height: 44.0}}
  """
  @spec locate(atom() | String.t()) :: {:ok, map()} | {:error, :not_found}
  def locate(tag_or_label) do
    search_str = if is_atom(tag_or_label), do: Atom.to_string(tag_or_label), else: tag_or_label

    case accessibility_tree() do
      {:ok, elements} ->
        match =
          Enum.find(elements, fn el ->
            label = if is_binary(el[:label]), do: el[:label], else: ""
            id = if is_binary(el[:id]), do: el[:id], else: ""
            String.contains?(label, search_str) or String.contains?(id, search_str)
          end)

        case match do
          nil -> {:error, :not_found}
          el -> {:ok, el[:frame]}
        end

      {:error, _} = err ->
        err
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp nav(node, action) do
    :rpc.call(node, GenServer, :call, [:mob_screen, {:navigate, action}])
    :ok
  end

  defp rpc(node, call) do
    :rpc.call(node, GenServer, :call, [:mob_screen, call])
  end

  # Query the iOS simulator accessibility tree via idb.
  # NOTE: intended to run on the dev machine (not via RPC on-device).
  defp accessibility_tree do
    case System.cmd("idb", ["ui", "describe-all", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        try do
          list = :json.decode(String.trim(output))

          elements =
            Enum.map(list, fn el ->
              frame = el["frame"] || %{}

              %{
                label: el["AXLabel"],
                id: el["AXUniqueId"],
                frame: %{
                  x: frame["x"] || 0.0,
                  y: frame["y"] || 0.0,
                  width: frame["width"] || 0.0,
                  height: frame["height"] || 0.0
                }
              }
            end)

          {:ok, elements}
        rescue
          # The iOS accessibility-tree payload is opaque JSON whose shape
          # has historically drifted across iOS versions. Narrow to the
          # concrete decode/extraction failures we can predict, so a real
          # bug (e.g. an arithmetic error inside the mapper) still raises
          # instead of getting silently downgraded to :parse_error.
          _ in [KeyError, ArgumentError, MatchError, FunctionClauseError, Protocol.UndefinedError] ->
            {:error, :parse_error}
        end

      {reason, _code} ->
        {:error, reason}
    end
  end

  defp search(%{type: _, props: _, children: _} = node, sub, path) do
    text = get_in(node, [:props, :text]) || ""
    own = if String.contains?(to_string(text), sub), do: [{path, node}], else: []

    children_results =
      node
      |> Map.get(:children, [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, i} -> search(child, sub, path ++ [i]) end)

    own ++ children_results
  end

  defp search(_, _sub, _path), do: []
end
