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
      nav_stack: list(),
      nav_action: term()
    }
  }

  defstruct assigns: %{},
            __mob__: %{
              screen: nil,
              platform: :android,
              root_view: nil,
              view_tree: %{},
              nav_stack: [],
              nav_action: nil
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
        nav_stack: [],
        nav_action: nil
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
  @spec put_mob(t(), atom(), term()) :: t()
  def put_mob(%__MODULE__{__mob__: mob} = socket, key, value) do
    %{socket | __mob__: Map.put(mob, key, value)}
  end

  # ── Navigation API ────────────────────────────────────────────────────────

  @doc """
  Push a new screen onto the navigation stack.

  `dest` is either a registered atom name (e.g. `:counter`) or a screen module
  (e.g. `MobDemo.CounterScreen`). `params` are passed to the new screen's
  `mount/3` as the first argument.

  The push is applied after the current callback returns — `do_render` in
  `Mob.Screen` detects the nav_action and mounts the new module.
  """
  @spec push_screen(t(), atom() | module(), map()) :: t()
  def push_screen(socket, dest, params \\ %{}) do
    put_mob(socket, :nav_action, {:push, dest, params})
  end

  @doc """
  Pop the current screen, returning to the previous one.

  No-op if already at the root of the stack.
  """
  @spec pop_screen(t()) :: t()
  def pop_screen(socket) do
    put_mob(socket, :nav_action, {:pop})
  end

  @doc """
  Pop the stack until the screen registered under `dest` is at the top.

  `dest` is a registered atom name or module. No-op if not found in history.
  """
  @spec pop_to(t(), atom() | module()) :: t()
  def pop_to(socket, dest) do
    put_mob(socket, :nav_action, {:pop_to, dest})
  end

  @doc """
  Pop to the root of the current navigation stack.
  """
  @spec pop_to_root(t()) :: t()
  def pop_to_root(socket) do
    put_mob(socket, :nav_action, {:pop_to_root})
  end

  @doc """
  Replace the entire navigation stack with a single new screen.

  Used for auth transitions (post-login → home with no back button to login).
  """
  @spec reset_to(t(), atom() | module(), map()) :: t()
  def reset_to(socket, dest, params \\ %{}) do
    put_mob(socket, :nav_action, {:reset, dest, params})
  end

  @doc """
  Switch to the named tab in a tab_bar or drawer layout.
  """
  @spec switch_tab(t(), atom()) :: t()
  def switch_tab(socket, tab) when is_atom(tab) do
    put_mob(socket, :nav_action, {:switch_tab, tab})
  end
end
