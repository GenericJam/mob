defmodule Mob.Router.Hooks do
  @moduledoc """
  Extension points plugins register on the router at runtime — typically
  from their `lifecycle.on_start`, which runs before the app's own
  `on_start` starts the root screen. Nothing to configure in the app.

  ## `:before_navigate`

  Called with the destination (a screen module or a route atom) before a
  navigation that **mounts** a screen — `push_screen`, `reset_to` (either
  form). Pops and `pop_to` go back to screens already mounted and don't
  call it. The hook returns:

    * `:ok` — navigate as usual.
    * `{:redirect, module}` — mount `module` instead (e.g. a "please
      update" screen).
    * `{:error, reason}` — refuse: navigation is left untouched and the
      current screen repaints, as for an unknown destination.

  Hooks run in the order registered; the first non-`:ok` answer wins. A
  hook that raises, exits, or returns anything else counts as
  `{:error, _}`. It runs in the router process, so it must be fast when
  there's nothing to do — a hook that has to fetch code (mob_deliver's
  just-in-time screens) blocks navigation while it does.

  ## `:after_first_render`

  Called once per VM, in its own process, after the router's first paint
  of the root screen: the supervision tree is up and the first screen has
  mounted and been handed to the renderer. Not called by test routers that
  don't render (`Mob.Router.start_link/3`).

      Mob.Router.Hooks.register(:before_navigate, {MyPlugin, :before_navigate, []})
      Mob.Router.Hooks.register(:after_first_render, {MyPlugin, :first_render, []})

  The destination is appended to a `:before_navigate` hook's arguments;
  `:after_first_render` hooks get the arguments as given.
  """

  require Logger

  @type hook :: :before_navigate | :after_first_render
  @type mfa_hook :: {module(), atom(), list()}
  @type verdict :: :ok | {:redirect, module()} | {:error, term()}

  @hooks {__MODULE__, :hooks}
  @first_render {__MODULE__, :first_render_fired}

  @doc "Registers `mfa` for `hook`. Registering the same MFA twice is a no-op."
  @spec register(hook(), mfa_hook()) :: :ok
  def register(hook, {module, fun, args} = mfa)
      when hook in [:before_navigate, :after_first_render] and is_atom(module) and is_atom(fun) and
             is_list(args) do
    all = :persistent_term.get(@hooks, %{})
    registered = Map.get(all, hook, [])

    unless mfa in registered,
      do: :persistent_term.put(@hooks, Map.put(all, hook, registered ++ [mfa]))

    :ok
  end

  @doc "Removes `mfa` from `hook`."
  @spec unregister(hook(), mfa_hook()) :: :ok
  def unregister(hook, mfa) do
    all = :persistent_term.get(@hooks, %{})
    :persistent_term.put(@hooks, Map.put(all, hook, List.delete(Map.get(all, hook, []), mfa)))
    :ok
  end

  @doc false
  @spec before_navigate(atom()) :: verdict()
  def before_navigate(dest) do
    Enum.reduce_while(registered(:before_navigate), :ok, fn {module, fun, args}, :ok ->
      case call(module, fun, args ++ [dest]) do
        :ok -> {:cont, :ok}
        {:redirect, target} = redirect when is_atom(target) -> {:halt, redirect}
        {:error, _} = error -> {:halt, error}
        other -> {:halt, {:error, {:bad_hook_return, {module, fun}, other}}}
      end
    end)
  end

  @doc false
  @spec after_first_render() :: :ok
  def after_first_render do
    unless :persistent_term.get(@first_render, false) do
      :persistent_term.put(@first_render, true)
      for {module, fun, args} <- registered(:after_first_render), do: spawn(module, fun, args)
    end

    :ok
  end

  defp registered(hook), do: :persistent_term.get(@hooks, %{}) |> Map.get(hook, [])

  defp call(module, fun, args) do
    apply(module, fun, args)
  catch
    kind, reason ->
      Logger.error(
        "[mob] navigation hook #{inspect(module)}.#{fun} failed: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      {:error, {:hook_crashed, {module, fun}}}
  end

  @doc false
  # Tests only: lets a test observe the once-per-VM first render again.
  @spec __reset_first_render__() :: :ok
  def __reset_first_render__ do
    :persistent_term.erase(@first_render)
    :ok
  end
end
