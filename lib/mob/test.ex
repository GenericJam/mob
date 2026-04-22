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
    timeout_ms  = Keyword.get(opts, :timeout_ms, 5000)
    interval_ms = Keyword.get(opts, :interval_ms, 200)
    deadline    = System.monotonic_time(:millisecond) + timeout_ms
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
    wait_for(node, fn tree ->
      Enum.any?(tree, fn {_type, label, value, _frame} ->
        String.contains?(to_string(label), text) or
        String.contains?(to_string(value), text)
      end)
    end, opts)
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
      {:error, _} = err -> err
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
        match = Enum.find(elements, fn el ->
          label = if is_binary(el[:label]), do: el[:label], else: ""
          id    = if is_binary(el[:id]),    do: el[:id],    else: ""
          String.contains?(label, search_str) or String.contains?(id, search_str)
        end)
        case match do
          nil -> {:error, :not_found}
          el  -> {:ok, el[:frame]}
        end
      {:error, _} = err -> err
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
          elements = Enum.map(list, fn el ->
            frame = el["frame"] || %{}
            %{
              label: el["AXLabel"],
              id:    el["AXUniqueId"],
              frame: %{
                x:      frame["x"] || 0.0,
                y:      frame["y"] || 0.0,
                width:  frame["width"] || 0.0,
                height: frame["height"] || 0.0
              }
            }
          end)
          {:ok, elements}
        rescue
          _ -> {:error, :parse_error}
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
