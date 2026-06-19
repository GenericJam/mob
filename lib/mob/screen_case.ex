defmodule Mob.ScreenCase do
  @moduledoc """
  The blessed way to unit-test a `Mob.Screen` in the BEAM, no device or
  emulator required. The screen-level analog of `Phoenix.LiveViewTest`.

  A `Mob.Screen` is a GenServer-shaped module: `mount/3` builds state,
  `handle_event/3` and `handle_info/2` mutate it, and `render/1` turns the
  assigns into a **view tree** (plain data: `%{type:, props:, children:}`). That
  last part is the key difference from LiveView: the screen produces a typed
  data structure, not an HTML string, so assertions are tree queries against
  real data instead of brittle string matching.

  This module drives those callbacks directly (the same thing the on-device
  runtime does) and gives you query helpers whose vocabulary matches `Mob.Test`
  (the device-side driver): `assigns/1`, `tree/1`, `find/3`, `flatten/1`. So a
  test reads the same whether it runs here in milliseconds or, later, against a
  real device.

      defmodule MyApp.CounterScreenTest do
        use Mob.ScreenCase

        test "increment bumps the count and the rendered text" do
          view = mount_screen(MyApp.CounterScreen)
          assert assigns(view).count == 0

          view = render_event(view, "increment")
          assert assigns(view).count == 1
          assert text(view) =~ "Count: 1"
          assert find(view, :button, tag: "increment")

          # cheap native-contract check: every node the screen emits is a
          # type the Compose / SwiftUI layer actually renders.
          assert_renderable(view)
        end
      end

  ## What this does and does not catch

  This is tier 1 of the testing pyramid: it exercises **logic, state, and the
  shape of the view tree**, fast and deterministically. `assert_renderable/2`
  adds a tier-2 **contract** check (does the tree only use renderable node
  types). Neither runs the native layer, so they cannot catch a node that
  renders wrong or behaves wrong on a real iOS/Android build. That needs a
  device test driven through `Mob.Test`. Weight your suite heavily toward this
  module, with a thin band of device tests for the things only hardware proves.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Mob.ScreenCase
    end
  end

  defmodule View do
    @moduledoc "A mounted screen under test: the screen module plus its current socket."
    @enforce_keys [:module, :socket]
    defstruct [:module, :socket]
  end

  # Renderable node types, derived at compile time from the same authoritative
  # source the ~MOB sigil validates against (priv/tags/{ios,android}.txt, one
  # PascalCase tag per line, converted to the snake_case `:type` atom the same
  # way the sigil does). Plus `:native_view`, the runtime-only escape hatch that
  # plugin / custom components serialize to and which has no template tag.
  @renderable_types (
                      read = fn name ->
                        path = Application.app_dir(:mob, "priv/tags/#{name}")

                        case File.read(path) do
                          {:ok, body} ->
                            body
                            |> String.split("\n", trim: true)
                            |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
                            |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))

                          _ ->
                            []
                        end
                      end

                      (read.("ios.txt") ++ read.("android.txt") ++ [:native_view])
                      |> MapSet.new()
                    )

  @doc """
  The set of node types the native layer can render: the core component tags
  plus `:native_view`. The contract surface `assert_renderable/2` checks against.
  """
  @spec renderable_types() :: MapSet.t(atom())
  def renderable_types, do: @renderable_types

  # ── Driving a screen ───────────────────────────────────────────────────────

  @doc """
  Mount a screen and return a `View` handle. Calls `Mob.Socket.new/1` then the
  screen's `mount/3`, asserting it returns `{:ok, socket}`.
  """
  @spec mount_screen(module(), map(), map()) :: View.t()
  def mount_screen(module, params \\ %{}, session \\ %{}) when is_atom(module) do
    socket = Mob.Socket.new(module)

    case module.mount(params, session, socket) do
      {:ok, %Mob.Socket{} = socket} ->
        %View{module: module, socket: socket}

      other ->
        raise ArgumentError,
              "#{inspect(module)}.mount/3 must return {:ok, socket}, got: #{inspect(other)}"
    end
  end

  @doc "Dispatch a `handle_event/3` (the explicit-event style) and return the updated `View`."
  @spec render_event(View.t(), String.t(), map()) :: View.t()
  def render_event(%View{module: module, socket: socket} = view, event, params \\ %{})
      when is_binary(event) do
    {:noreply, socket} = module.handle_event(event, params, socket)
    %{view | socket: socket}
  end

  @doc """
  Deliver a message to the screen's `handle_info/2` and return the updated
  `View`. This is how taps reach a screen on device (a `Button`'s `on_tap`
  sends a message), so it is the in-BEAM equivalent of a tap.
  """
  @spec render_info(View.t(), term()) :: View.t()
  def render_info(%View{module: module, socket: socket} = view, message) do
    {:noreply, socket} = module.handle_info(message, socket)
    %{view | socket: socket}
  end

  @doc "The screen's current assigns. Mirrors `Mob.Test.assigns/1`."
  @spec assigns(View.t()) :: map()
  def assigns(%View{socket: socket}), do: socket.assigns

  # ── Querying the rendered tree ───────────────────────────────────────────────

  @doc "Render the screen to its current view tree. Mirrors `Mob.Test.tree/1`."
  @spec tree(View.t() | map()) :: map()
  def tree(%View{module: module, socket: socket}), do: module.render(socket.assigns)
  def tree(%{type: _} = node), do: node

  @doc "Every node in the tree, depth-first. Mirrors `Mob.Test.flatten_tree/1`."
  @spec flatten(View.t() | map()) :: [map()]
  def flatten(view_or_tree), do: do_flatten(tree(view_or_tree))

  defp do_flatten(%{type: _} = node) do
    children = Map.get(node, :children, []) || []
    [node | Enum.flat_map(List.wrap(children), &do_flatten/1)]
  end

  defp do_flatten(_), do: []

  @doc """
  All nodes of `type` whose props are a superset of `props`. Mirrors
  `Mob.Test.find/2`, but matches on the typed tree rather than a substring.

      find_all(view, :button, tag: "increment")
  """
  @spec find_all(View.t() | map(), atom(), keyword()) :: [map()]
  def find_all(view_or_tree, type, props \\ []) when is_atom(type) do
    want = Map.new(props)

    view_or_tree
    |> flatten()
    |> Enum.filter(fn node ->
      node.type == type and props_match?(Map.get(node, :props, %{}), want)
    end)
  end

  @doc "The first node matching `find_all/3`, or `nil`."
  @spec find(View.t() | map(), atom(), keyword()) :: map() | nil
  def find(view_or_tree, type, props \\ []) do
    view_or_tree |> find_all(type, props) |> List.first()
  end

  @doc "Concatenated text of every `:text` node in the tree, joined by spaces."
  @spec text(View.t() | map()) :: String.t()
  def text(view_or_tree) do
    view_or_tree
    |> find_all(:text)
    |> Enum.map(&(&1.props[:text] || ""))
    |> Enum.join(" ")
  end

  defp props_match?(have, want) do
    Enum.all?(want, fn {k, v} -> Map.get(have, k) == v end)
  end

  # ── The native contract check (tier 2) ──────────────────────────────────────

  @doc """
  Assert every node in the tree is a type the native layer can render. Returns
  the tree on success so it composes; flunks (with the offending types) if a
  node uses a type that has no Compose / SwiftUI renderer.

  This catches the "you emitted a node the native side can't draw" class of bug
  at `mix test` time, no device needed. Pass extra types a plugin or your own
  app registers via `:extra`:

      assert_renderable(view, extra: [:gauge])
  """
  @spec assert_renderable(View.t() | map(), keyword()) :: map()
  def assert_renderable(view_or_tree, opts \\ []) do
    tree = tree(view_or_tree)
    allowed = MapSet.union(@renderable_types, MapSet.new(Keyword.get(opts, :extra, [])))

    offenders =
      tree
      |> do_flatten()
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(allowed, &1))

    if offenders == [] do
      tree
    else
      ExUnit.Assertions.flunk("""
      view tree uses node type(s) the native layer cannot render: #{inspect(offenders)}

      Renderable types come from mob's priv/tags/{ios,android}.txt (plus :native_view).
      If one of these is a plugin or custom component, pass it via
      `assert_renderable(view, extra: #{inspect(offenders)})`. Otherwise it is
      likely a typo or a component with no registered native renderer.
      """)
    end
  end
end
