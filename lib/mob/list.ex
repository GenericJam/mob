defmodule Mob.List do
  @moduledoc """
  Data-driven list component.

  A `type: :list` node in your render tree is shorthand for a scrollable list
  backed by Elixir data. Mob expands it into a `lazy_list` before rendering,
  wrapping each row in a tappable container.

  ## Basic usage

  The default renderer turns each item into a text row. No setup needed:

      %{
        type:  :list,
        props: %{id: :my_list, items: assigns.names},
        children: []
      }

  Handle selections in `handle_info/2`:

      def handle_info({:select, :my_list, index}, socket) do
        item = Enum.at(socket.assigns.names, index)
        {:noreply, Mob.Socket.assign(socket, :selected, item)}
      end

  ## Custom renderer

  Register a renderer in `mount/3` to control how each item looks:

      def mount(_params, _session, socket) do
        socket =
          socket
          |> Mob.Socket.assign(:items, load_items())
          |> Mob.List.put_renderer(:my_list, fn %{name: name, subtitle: sub} ->
            %{
              type: :column,
              props: %{padding: 12},
              children: [
                %{type: :text, props: %{text: name,  text_size: :base}, children: []},
                %{type: :text, props: %{text: sub,   text_size: :sm, text_color: :gray_500}, children: []}
              ]
            }
          end)
        {:ok, socket}
      end

  ## Default renderer rules

  When no custom renderer is registered:
  - Binary → text row with the string
  - `%{label: _}` → text row with the label
  - `%{text: _}`  → text row with the text
  - Anything else → `inspect/1` fallback
  """

  @doc """
  Register a custom item renderer for a list.

  `id` must match the `:id` prop on the `type: :list` node.
  `renderer` is a 1-arity function that receives one item and returns a node map.

  Call this from `mount/3` or `handle_info/2` — it is stored in `socket.__mob__`
  and picked up at render time.
  """
  @spec put_renderer(Mob.Socket.t(), atom(), (term() -> map())) :: Mob.Socket.t()
  def put_renderer(socket, id, renderer) when is_atom(id) and is_function(renderer, 1) do
    existing = Map.get(socket.__mob__, :list_renderers, %{})
    Mob.Socket.put_mob(socket, :list_renderers, Map.put(existing, id, renderer))
  end

  @doc """
  The default item renderer. Handles binaries, maps with `:label`/`:text`, and
  falls back to `inspect/1` for anything else.
  """
  @spec default_renderer(term()) :: map()
  def default_renderer(item) when is_binary(item) do
    text_row(item)
  end

  def default_renderer(%{label: label}) do
    text_row(to_string(label))
  end

  def default_renderer(%{text: text}) do
    text_row(to_string(text))
  end

  def default_renderer(item) do
    text_row(inspect(item))
  end

  @doc """
  Walk a render tree and expand all `type: :list` nodes into `lazy_list` nodes.

  Called internally by `Mob.Screen` before passing the tree to `Mob.Renderer`.
  `renderers` is the `list_renderers` map from `socket.__mob__`. `pid` is the
  screen process (used as the tap target for row-select events).
  """
  @spec expand(map(), map(), pid()) :: map()
  def expand(%{type: :list, props: props} = _node, renderers, pid) do
    id = Map.fetch!(props, :id)
    items = Map.get(props, :items, [])
    renderer = Map.get(renderers, id, &default_renderer/1)

    children =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        row = renderer.(item)

        %{
          type: :box,
          props: %{on_tap: {pid, {:list, id, :select, index}}},
          children: [row]
        }
      end)

    # Drop list-specific props; pass through any others (e.g. on_end_reached)
    list_props = Map.drop(props, [:id, :items])
    %{type: :lazy_list, props: list_props, children: children}
  end

  def expand(%{type: type, props: props, children: children}, renderers, pid) do
    %{
      type: type,
      props: props,
      children: Enum.map(children, &expand(&1, renderers, pid))
    }
  end

  def expand(node, _renderers, _pid), do: node

  # ── Private ──────────────────────────────────────────────────────────────────

  defp text_row(text) do
    %{
      type: :text,
      props: %{text: text, text_size: :base, text_color: :on_surface, padding: 16},
      children: []
    }
  end
end
