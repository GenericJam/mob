defmodule Mob.Socket do
  @moduledoc """
  The socket struct passed through all Mob.Screen and Mob.Component callbacks.

  Holds two things:
  - `assigns` — the public data map your `render/1` function reads via
    `assigns.foo`, or the `@foo` shorthand inside a `~MOB` template
    (the sigil rewrites `@foo` to `assigns.foo`, matching Phoenix HEEx)
  - `__mob__` — internal Mob metadata (screen module, platform, view refs, nav stack)

  You interact with a socket via `assign/2` and `assign/3`. Never mutate `__mob__`
  directly — it is an internal contract.
  """

  @type platform :: :android | :ios
  @type transition :: :push | :pop | :reset

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
  Update an existing assign by applying `fun` to its current value.

      socket = update(socket, :count, fn count -> count + 1 end)

  Raises `KeyError` if `key` is not already assigned. Mirrors
  `Phoenix.LiveView.update/3`.
  """
  @spec update(t(), atom(), (term() -> term())) :: t()
  def update(%__MODULE__{assigns: assigns} = socket, key, fun)
      when is_atom(key) and is_function(fun, 1) do
    %{socket | assigns: Map.put(assigns, key, fun.(Map.fetch!(assigns, key)))}
  end

  @doc """
  Assign `key` only if it is not already present, computing the value lazily.

      socket = assign_new(socket, :user, fn -> fetch_user(id) end)

  `fun` runs only when `key` is absent, so it's the cheap way to set a default
  or memoize a lookup across re-renders. Mirrors `Phoenix.LiveView.assign_new/3`.
  """
  @spec assign_new(t(), atom(), (-> term())) :: t()
  def assign_new(%__MODULE__{assigns: assigns} = socket, key, fun)
      when is_atom(key) and is_function(fun, 0) do
    case assigns do
      %{^key => _} -> socket
      _ -> %{socket | assigns: Map.put(assigns, key, fun.())}
    end
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
  Replace the current navigation stack with a single new screen.

  Used for auth transitions (post-login → home with no back button to login).
  Pass `transition: :push` or `transition: :pop` when the reset still represents
  directional movement, such as switching between custom tabs. The default,
  `:reset`, cross-fades. Pass `scope: :all` for an auth boundary that must also
  discard every parked tab stack. The default `scope: :stack` preserves the
  established current-stack-only behavior.

  Raises `ArgumentError` on any other transition — including `:none`, which
  would replace the stack while telling the platform no navigation happened,
  leaving the incoming screen wearing the outgoing one's view identities.
  """
  @spec reset_to(t(), atom() | module(), map(), [
          {:transition, transition()} | {:scope, :stack | :all}
        ]) :: t()
  def reset_to(socket, dest, params \\ %{}, opts \\ []) do
    transition = validate_transition!(Keyword.get(opts, :transition, :reset), "reset_to/4")
    scope = validate_reset_scope!(Keyword.get(opts, :scope, :stack))

    case scope do
      :stack -> put_mob(socket, :nav_action, {:reset, dest, params, transition})
      :all -> put_mob(socket, :nav_action, {:reset, dest, params, transition, :all})
    end
  end

  @valid_transitions [:push, :pop, :reset]

  # Checked here rather than left to the native layer, for two different
  # reasons.
  #
  # An unrecognised atom is merely wrong-looking: `set_transition/1` accepts any
  # atom and the platform falls back to no animation, so a typo would silently
  # produce the wrong motion with nothing to point at.
  #
  # `:none` is worse, and is rejected rather than allowed. It is the one value
  # that suppresses the navigation-version bump (`ios/mob_nif.m`'s
  # `mob_bump_frame_generation`, `MobViewModel.navVersion`, and the `.id()` on
  # the root view). A reset stops every screen process and replaces the stack,
  # so telling native it was not navigation leaves SwiftUI diffing the incoming
  # tree into the outgoing screen's view identities — a `TextField` at the same
  # position inherits the old screen's text and focus, and scroll offsets
  # survive a stack that no longer exists.
  defp validate_transition!(transition, _function) when transition in @valid_transitions,
    do: transition

  defp validate_transition!(other, function) do
    raise ArgumentError,
          "Mob.Socket.#{function}: invalid transition #{inspect(other)}. " <>
            "Expected one of #{inspect(@valid_transitions)}."
  end

  defp validate_reset_scope!(scope) when scope in [:stack, :all], do: scope

  defp validate_reset_scope!(other) do
    raise ArgumentError,
          "Mob.Socket.reset_to/4: invalid scope #{inspect(other)}. " <>
            "Expected one of [:stack, :all]."
  end

  @doc """
  Switch to the named tab in a tab_bar or drawer layout.

  By default, switching tabs has no animation. Pass `transition: :push`,
  `transition: :pop`, or `transition: :reset` when the tab order implies
  directional movement or a cross-fade. `mount_params: %{...}` supplies the
  params for the target root's first mount. A previously mounted stack ignores
  later mount params and restores its existing screen state.
  """
  @spec switch_tab(t(), atom()) :: t()
  def switch_tab(socket, tab) when is_atom(tab) do
    put_mob(socket, :nav_action, {:switch_tab, tab})
  end

  @spec switch_tab(t(), atom(), [
          {:transition, transition()} | {:mount_params, map()}
        ]) :: t()
  def switch_tab(socket, tab, opts) when is_atom(tab) and is_list(opts) do
    transition =
      case Keyword.fetch(opts, :transition) do
        {:ok, value} -> validate_transition!(value, "switch_tab/3")
        :error -> :none
      end

    case Keyword.fetch(opts, :mount_params) do
      {:ok, mount_params} when is_map(mount_params) ->
        put_mob(socket, :nav_action, {:switch_tab, tab, transition, mount_params})

      {:ok, mount_params} ->
        raise ArgumentError,
              "Mob.Socket.switch_tab/3: invalid mount_params #{inspect(mount_params)}. " <>
                "Expected a map."

      :error when transition == :none ->
        switch_tab(socket, tab)

      :error ->
        put_mob(socket, :nav_action, {:switch_tab, tab, transition})
    end
  end
end
