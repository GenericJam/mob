defmodule Mob.Renderer do
  @moduledoc """
  Walks a component tree (nested maps) and issues NIF calls to build
  the native view hierarchy.

  A component tree node looks like:

      %{
        type: :column,           # atom — looked up in Mob.Registry
        props: %{padding: 16},   # keyword props applied after creation
        children: [...]          # nested nodes, recursively rendered
      }

  `render/3` returns `{:ok, root_view_ref}` where `root_view_ref` is an
  opaque Erlang resource (a reference to a native View object).

  ## Injecting a mock NIF

  Pass a module as the third argument to swap in a test double:

      Mob.Renderer.render(tree, :android, MockNIF)

  In production the default is `:mob_nif`.
  """

  @default_nif :mob_nif

  @doc """
  Render a component tree for a given platform and return the root view ref.
  """
  @spec render(map(), atom(), module() | atom()) :: {:ok, term()} | {:error, term()}
  def render(node, platform, nif_mod \\ @default_nif)

  def render(%{type: type, props: props, children: children}, platform, nif) do
    with {:ok, view_ref} <- create_view(type, props, nif),
         :ok             <- apply_props(view_ref, props, nif),
         :ok             <- render_children(view_ref, children, platform, nif, type) do
      {:ok, view_ref}
    end
  end

  # ── View creation ─────────────────────────────────────────────────────────

  defp create_view(:text, %{text: text}, nif), do: apply(nif, :create_label, [text])
  defp create_view(:text, _props, nif),         do: apply(nif, :create_label, [""])
  defp create_view(:button, %{label: label}, nif), do: apply(nif, :create_button, [label])
  defp create_view(:button, %{text: text}, nif),   do: apply(nif, :create_button, [text])
  defp create_view(:button, _props, nif),           do: apply(nif, :create_button, [""])
  defp create_view(:column, _props, nif),  do: apply(nif, :create_column, [])
  defp create_view(:row, _props, nif),     do: apply(nif, :create_row, [])
  defp create_view(:scroll, _props, nif),  do: apply(nif, :create_scroll, [])

  defp create_view(unknown, _props, _nif),
    do: {:error, {:unknown_component, unknown}}

  # ── Prop application ──────────────────────────────────────────────────────

  defp apply_props(view_ref, props, nif) do
    Enum.reduce_while(props, :ok, fn
      {:padding, dp}, :ok ->
        apply(nif, :set_padding, [view_ref, dp])
        {:cont, :ok}

      {:background, color}, :ok ->
        apply(nif, :set_background_color, [view_ref, color])
        {:cont, :ok}

      {:text_color, color}, :ok ->
        apply(nif, :set_text_color, [view_ref, color])
        {:cont, :ok}

      {:text_size, sp}, :ok ->
        apply(nif, :set_text_size, [view_ref, sp * 1.0])
        {:cont, :ok}

      {:on_tap, pid}, :ok ->
        apply(nif, :on_tap, [view_ref, pid])
        {:cont, :ok}

      # Props consumed at creation time — skip here
      {k, _}, :ok when k in [:text, :label] ->
        {:cont, :ok}

      # Unknown props are silently ignored for forward-compat
      {_k, _v}, :ok ->
        {:cont, :ok}
    end)
  end

  # ── Children ──────────────────────────────────────────────────────────────

  defp render_children(parent_ref, children, platform, nif, parent_type) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      case render(child, platform, nif) do
        {:ok, child_ref} ->
          # For scroll views the NIF expects add_child on the inner layout,
          # but from the Elixir side we always pass the scroll ref — the NIF
          # (or MobBridge) resolves the inner layout via getTag.
          is_row = parent_type == :row
          apply(nif, :add_child, [parent_ref, child_ref, is_row])
          {:cont, :ok}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end
end
