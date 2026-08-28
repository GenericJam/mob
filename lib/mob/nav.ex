defmodule Mob.Nav do
  @moduledoc """
  Multi-stack navigation state.

  Replaces the single `nav_history` list that `Mob.Screen` used to carry. One
  `Mob.App.stack/2` declaration becomes one independent stack here: each keeps
  its own history *and* its own current screen, so switching away from a stack
  and back restores exactly where you were rather than re-mounting the root.

  That is what makes `Mob.App.tab_bar/1` and `drawer/1` representable. Both have
  been public API in `Mob.App`'s moduledoc for a long time while the runtime
  behind them could only hold one history — see
  `decisions/2026-08-27-screen-process-architecture.md`.

  ## Shape

  The *active* stack's current screen is deliberately **not** stored here. It
  lives where it always did, in `Mob.Screen`'s `{module, socket}`, and this
  struct holds only the active stack's `history` plus the fully parked state of
  every inactive stack. Keeping the hot path untouched is the point: an ordinary
  message to the active screen reads and writes the same two variables it did
  before, and only `switch/3` moves state in or out of `parked`.

  * `active` — name of the stack the current screen belongs to (`nil` when the
    app declares no stacks at all, i.e. a bare `start_root/1` with no layout)
  * `history` — the active stack's history, head = most recent, exactly the list
    `Mob.Screen` used to hold
  * `parked` — `%{name => %{current: entry, history: [entry]}}` for inactive
    stacks. Never contains `active`.
  * `order` — declared stack order, for tab-index mapping
  * `roots` — `%{name => root_module}`, used to mount a stack on first visit

  ## Lazy stacks

  A stack materializes on first visit. Until you switch to it, it has no socket
  and has never mounted — matching UIKit's `UITabBarController`, which does not
  instantiate a tab's view controller until it is first selected. After the
  first visit its state is retained for the lifetime of the app.
  """

  alias Mob.Socket

  @type entry :: {module(), Socket.t()}
  @type stack_name :: atom()
  @type parked_stack :: %{current: entry(), history: [entry()]}

  @type t :: %__MODULE__{
          active: stack_name() | nil,
          history: [entry()],
          parked: %{stack_name() => parked_stack()},
          order: [stack_name()],
          roots: %{stack_name() => module()}
        }

  defstruct active: nil, history: [], parked: %{}, order: [], roots: %{}

  @doc """
  An empty single-stack navigation state.

  Equivalent to the old `nav_history = []`. Used when no navigation layout has
  been declared, or in tests that start a screen directly.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Build navigation state from a declared layout, with `current_module` as the
  screen that is already mounted.

  `layout` is the map returned by `Mob.App.stack/2`, `tab_bar/1`, or `drawer/1`
  (or `nil` when the app declares none). The active stack is the one whose root
  is `current_module`; when no stack declares that module as its root the first
  declared stack is used, so the running screen still belongs somewhere and is
  preserved across a switch. Its state is never discarded — only its label is a
  guess, and only in that fallback case.
  """
  @spec from_layout(map() | nil, module()) :: t()
  def from_layout(nil, _current_module), do: new()

  def from_layout(layout, current_module) when is_map(layout) do
    declared = declared_stacks(layout)

    case declared do
      [] ->
        new()

      [{first_name, _} | _] ->
        roots = Map.new(declared)
        order = Enum.map(declared, fn {name, _root} -> name end)

        active =
          Enum.find_value(declared, first_name, fn {name, root} ->
            if root == current_module, do: name
          end)

        %__MODULE__{active: active, history: [], parked: %{}, order: order, roots: roots}
    end
  end

  @doc "The active stack's history — head is the most recent entry."
  @spec history(t()) :: [entry()]
  def history(%__MODULE__{history: history}), do: history

  @doc "Replace the active stack's history."
  @spec put_history(t(), [entry()]) :: t()
  def put_history(%__MODULE__{} = nav, history) when is_list(history) do
    %{nav | history: history}
  end

  @doc "Name of the active stack, or `nil` when no layout was declared."
  @spec active(t()) :: stack_name() | nil
  def active(%__MODULE__{active: active}), do: active

  @doc "Declared stack names, in declaration order."
  @spec stacks(t()) :: [stack_name()]
  def stacks(%__MODULE__{order: order}), do: order

  @doc """
  Switch the active stack to `name`, parking `current_entry` under the stack it
  belongs to.

  Returns one of:

  * `{:switched, nav, entry}` — the target has been visited before; `entry` is
    the `{module, socket}` to make current again, with no re-mount
  * `{:mount_root, nav, root_module}` — first visit; the caller mounts
    `root_module` and makes it current
  * `:noop` — `name` is already active, or is not a declared stack

  `:noop` on an unknown stack is deliberate: `Mob.Socket.switch_tab/2` takes any
  atom, and a typo should leave navigation untouched rather than crash the
  screen or strand it on a stack that does not exist.
  """
  @spec switch(t(), stack_name(), entry()) ::
          {:switched, t(), entry()} | {:mount_root, t(), module()} | :noop
  def switch(%__MODULE__{active: active}, name, _current_entry) when active == name, do: :noop

  def switch(%__MODULE__{} = nav, name, current_entry) when is_atom(name) do
    case Map.fetch(nav.roots, name) do
      :error ->
        :noop

      {:ok, root} ->
        parked = park_current(nav, current_entry)

        case Map.fetch(parked, name) do
          {:ok, %{current: entry, history: history}} ->
            nav = %{nav | active: name, history: history, parked: Map.delete(parked, name)}
            {:switched, nav, entry}

          :error ->
            {:mount_root, %{nav | active: name, history: [], parked: parked}, root}
        end
    end
  end

  # An app with no declared layout has nowhere to park its screen. That state
  # belongs to no stack, so it is left where it is rather than filed under a
  # name that was never declared.
  defp park_current(%__MODULE__{active: nil, parked: parked}, _current_entry), do: parked

  defp park_current(%__MODULE__{active: active, history: history, parked: parked}, current_entry) do
    Map.put(parked, active, %{current: current_entry, history: history})
  end

  # Flatten a layout declaration into [{stack_name, root_module}] preserving
  # declaration order. Unlike Nav.Registry's route table this keeps the stacks
  # distinct — that table records only that a name exists.
  defp declared_stacks(%{type: :stack, name: name, root: root}), do: [{name, root}]

  defp declared_stacks(%{type: type, branches: branches})
       when type in [:tab_bar, :drawer] and is_list(branches) do
    Enum.flat_map(branches, &declared_stacks/1)
  end

  defp declared_stacks(_), do: []
end
