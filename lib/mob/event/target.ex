defmodule Mob.Event.Target do
  @moduledoc """
  Resolves a `target:` spec to a concrete delivery pid.

  See `guides/event_model.md` for the full event model.

  ## Forms

  | Form | Resolves to | When checked |
  |------|-------------|--------------|
  | `:parent` | nearest stateful ancestor | render time |
  | `:screen` | the containing screen | render time |
  | `{:component, id}` | named ancestor component | render time |
  | atom | registered process | event time (best-effort) |
  | pid | that pid | n/a |
  | `{:via, mod, key}` | whatever `mod` resolves it to | event time |

  Resolution returns either `{:ok, pid}` or `{:error, reason}`. Callers decide
  how to handle errors — typically log + drop (for in-tree, this means the
  target was unmounted; for external, it was never registered).
  """

  alias Mob.Event.Address

  @typedoc """
  The user-facing form passed in `target:` props.
  """
  @type spec ::
          :parent
          | :screen
          | {:component, Address.id()}
          | atom()
          | pid()
          | {:via, module(), term()}

  @typedoc """
  The render-time scope used to resolve in-tree targets.

  - `screen_pid` — the screen GenServer's pid
  - `component_chain` — list of `{id, pid}` from outermost to innermost
    stateful ancestor of the widget being registered
  """
  @type render_scope :: %{
          required(:screen_pid) => pid(),
          required(:component_chain) => [{Address.id(), pid()}]
        }

  @doc """
  Resolve a target spec to a pid using the render-time scope.

  In-tree forms (`:parent`, `:screen`, `{:component, id}`) are resolved
  against `scope`. External forms (atom/pid/via) are resolved against the
  process registry at the moment of resolution.

  Returns `{:ok, pid}` or `{:error, reason}`.

  ## Examples

      iex> Mob.Event.Target.resolve(:parent, %{screen_pid: self(), component_chain: []})
      {:ok, self()}

      iex> Mob.Event.Target.resolve(:screen, %{screen_pid: self(), component_chain: []})
      {:ok, self()}

      iex> Mob.Event.Target.resolve(self(), %{screen_pid: self(), component_chain: []})
      {:ok, self()}
  """
  @spec resolve(spec(), render_scope()) :: {:ok, pid()} | {:error, atom()}
  def resolve(:parent, %{component_chain: chain, screen_pid: screen_pid}) do
    case List.last(chain) do
      nil -> {:ok, screen_pid}
      {_id, pid} -> {:ok, pid}
    end
  end

  def resolve(:screen, %{screen_pid: screen_pid}), do: {:ok, screen_pid}

  def resolve({:component, id}, %{component_chain: chain}) do
    case Enum.find(chain, fn {cid, _pid} -> cid == id end) do
      {_, pid} -> {:ok, pid}
      nil -> {:error, {:component_not_in_ancestors, id}}
    end
  end

  def resolve(pid, _scope) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :dead_pid}
  end

  def resolve(name, _scope) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, {:not_registered, name}}
      pid -> {:ok, pid}
    end
  end

  def resolve({:via, mod, key} = via, _scope) when is_atom(mod) do
    # GenServer.whereis/1 narrows to `pid | nil` for `{:via, _, _}`
    # inputs (the registry callbacks normalize their result before
    # returning). The historical `{_name, _node}` arm came from
    # treating `GenServer.whereis/1`'s full @spec — that variant
    # only fires for `{name, node}` inputs, which this clause never
    # passes.
    case GenServer.whereis(via) do
      nil -> {:error, {:via_not_resolvable, mod, key}}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  def resolve(other, _scope), do: {:error, {:invalid_target, other}}

  @doc """
  Classify a target spec as `:in_tree` or `:external`.

  In-tree targets get framework guarantees (staleness check, lifecycle
  cleanup); external targets are best-effort delivery.
  """
  @spec classify(spec()) :: :in_tree | :external
  def classify(:parent), do: :in_tree
  def classify(:screen), do: :in_tree
  def classify({:component, _}), do: :in_tree
  def classify(_), do: :external
end
