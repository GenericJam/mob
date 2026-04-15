defmodule Mob.Renderer do
  @moduledoc """
  Serializes a component tree to JSON and passes it to the platform NIF in
  a single call. Compose (Android) and SwiftUI (iOS) handle diffing and
  rendering internally.

  A component tree node:

      %{
        type: :column,
        props: %{padding: 16, background: 0xFFFFFFFF},
        children: [
          %{type: :text,   props: %{text: "Hello"}, children: []},
          %{type: :button, props: %{text: "Tap",  on_tap: self()}, children: []}
        ]
      }

  `on_tap` PIDs are replaced with integer handles before serialization.
  The NIF's `register_tap/1` returns the handle; `mob_send_tap(handle)`
  in C routes the tap back to the correct PID via `enif_send`.

  ## Injecting a mock NIF

      Mob.Renderer.render(tree, :android, MockNIF)
  """

  @default_nif :mob_nif

  @doc """
  Render a component tree for the given platform.

  Clears the tap registry, serializes the tree to JSON, and calls `set_root/1`
  on the NIF. Returns `{:ok, :json_tree}` — there is no view ref to track.

  `transition` is an atom (`:push`, `:pop`, `:reset`, `:none`) that tells the
  platform which animation to play. Defaults to `:none` (instant swap).
  """
  @spec render(map(), atom(), module() | atom(), atom()) :: {:ok, :json_tree} | {:error, term()}
  def render(tree, _platform, nif \\ @default_nif, transition \\ :none) do
    nif.clear_taps()
    nif.set_transition(transition)

    json =
      tree
      |> prepare(nif)
      |> :json.encode()
      |> IO.iodata_to_binary()

    nif.set_root(json)
    {:ok, :json_tree}
  end

  # ── Tree preparation ─────────────────────────────────────────────────────────
  # Converts atom keys → string keys and registers on_tap PIDs for handles.

  defp prepare(%{type: type, props: props, children: children}, nif) do
    %{
      "type"     => Atom.to_string(type),
      "props"    => prepare_props(props, nif),
      "children" => Enum.map(children, &prepare(&1, nif))
    }
  end

  defp prepare_props(props, nif) do
    Map.new(props, fn
      {:on_tap, pid} when is_pid(pid) ->
        # Simple pid — NIF sends {:tap, :ok}
        handle = nif.register_tap(pid)
        {"on_tap", handle}

      {:on_tap, {pid, tag}} when is_pid(pid) ->
        # Tagged pid — NIF sends {:tap, tag}
        handle = nif.register_tap({pid, tag})
        {"on_tap", handle}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end
end
