defmodule Mob.Socket do
  @moduledoc """
  The socket struct passed through all Mob.Screen and Mob.Component callbacks.

  Holds two things:
  - `assigns` — the public data map your `render/1` function reads from `@assigns`
  - `__mob__` — internal Mob metadata (screen module, platform, view refs, nav stack)

  You interact with a socket via `assign/2` and `assign/3`. Never mutate `__mob__`
  directly — it is an internal contract.
  """

  @type platform :: :android | :ios

  @type t :: %__MODULE__{
    assigns: map(),
    __mob__: %{
      screen: module() | nil,
      platform: platform(),
      root_view: term(),
      view_tree: map(),
      nav_stack: list()
    }
  }

  defstruct assigns: %{},
            __mob__: %{
              screen: nil,
              platform: :android,
              root_view: nil,
              view_tree: %{},
              nav_stack: []
            }

  @doc """
  Create a new socket for the given screen module.

  Options:
  - `:platform` — `:android` (default) or `:ios`
  """
  @spec new(module(), keyword()) :: t()
  def new(screen, opts \\ []) do
    platform = Keyword.get(opts, :platform, :android)
    %__MODULE__{
      assigns: %{},
      __mob__: %{
        screen: screen,
        platform: platform,
        root_view: nil,
        view_tree: %{},
        nav_stack: []
      }
    }
  end

  @doc """
  Assign a single key/value pair into the socket's assigns.

      socket = assign(socket, :count, 0)
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{assigns: assigns} = socket, key, value) when is_atom(key) do
    %{socket | assigns: Map.put(assigns, key, value)}
  end

  @doc """
  Assign multiple key/value pairs at once from a keyword list or map.

      socket = assign(socket, count: 0, name: "test")
      socket = assign(socket, %{count: 0})
  """
  @spec assign(t(), keyword() | map()) :: t()
  def assign(%__MODULE__{assigns: assigns} = socket, kw) when is_list(kw) or is_map(kw) do
    %{socket | assigns: Map.merge(assigns, Map.new(kw))}
  end

  @doc """
  Store the root view ref returned by the renderer into `__mob__.root_view`.
  Called internally after the initial render.
  """
  @spec put_root_view(t(), term()) :: t()
  def put_root_view(%__MODULE__{__mob__: mob} = socket, ref) do
    %{socket | __mob__: %{mob | root_view: ref}}
  end

  @doc false
  def put_mob(%__MODULE__{__mob__: mob} = socket, key, value) do
    %{socket | __mob__: Map.put(mob, key, value)}
  end
end
