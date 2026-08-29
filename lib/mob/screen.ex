defmodule Mob.Screen do
  @moduledoc """
  Behaviour and GenServer wrapper for a Mob screen.

  Each live screen runs in its own `Mob.Screen.Server` process holding a
  `Mob.Socket`. `Mob.Router` owns them: it holds the navigation state, starts
  and stops screens, and restarts one that crashes.

  That gives you isolation — a buggy `handle_event` crashes its own screen and
  the router restarts it without taking down navigation, sibling screens,
  background services, or the BEAM. The router is not an OTP `Supervisor`; it
  restarts screens itself because only it knows where in the navigation a
  crashed screen sat (see
  `decisions/2026-08-28-screen-processes-and-supervision.md`). A restarted
  screen re-mounts and loses its assigns.

  The functions below delegate to `Mob.Router`; this module is the behaviour
  your screens implement.

  Lifecycle callbacks (`mount`, `render`, `handle_event`, `handle_info`,
  `terminate`) map directly to the GenServer lifecycle, so the BEAM's existing
  tools (selective receive, monitors, hot code push) work on screens without
  any Mob-specific scaffolding.

  ## Usage

      defmodule MyApp.CounterScreen do
        use Mob.Screen

        def mount(_params, _session, socket) do
          {:ok, Mob.Socket.assign(socket, :count, 0)}
        end

        def render(assigns) do
          %{
            type: :column,
            props: %{},
            children: [
              %{type: :text, props: %{text: "Count: \#{assigns.count}"}, children: []}
            ]
          }
        end

        def handle_event("increment", _params, socket) do
          {:noreply, Mob.Socket.assign(socket, :count, socket.assigns.count + 1)}
        end
      end

  ## Starting a screen

      {:ok, pid} = Mob.Screen.start_link(MyApp.CounterScreen, %{})

  ## Dispatching events

      :ok = Mob.Screen.dispatch(pid, "increment", %{})
  """

  @type socket :: Mob.Socket.t()

  @callback mount(params :: map(), session :: map(), socket :: socket()) ::
              {:ok, socket()} | {:error, term()}

  @callback render(assigns :: map()) :: map()

  @callback handle_event(event :: String.t(), params :: map(), socket :: socket()) ::
              {:noreply, socket()} | {:reply, map(), socket()}

  @callback handle_info(message :: term(), socket :: socket()) ::
              {:noreply, socket()}

  @callback terminate(reason :: term(), socket :: socket()) :: term()

  @doc """
  Serialise assigns for persistence. Return a plain map of the keys you want
  restored on next launch. Defaults to the full assigns map minus any
  non-serialisable values (PIDs, references, ports, functions).

  Only called when `use Mob.Screen, vsn: N` (N > 0) or `persist: true`.
  """
  @callback dump_state(assigns :: map()) :: map()

  @doc """
  Reconstruct assigns from a previously persisted map.

  `stored_vsn` is the version that was current when the data was saved.
  Match on it to migrate old shapes:

      def load_state(1, stored), do: stored
      def load_state(0, stored), do: Map.put(stored, :new_field, :default)

  The returned map is merged into the socket's assigns after `mount/3` runs.
  Only called when stored data exists.
  """
  @callback load_state(stored_vsn :: non_neg_integer(), stored :: map()) :: map()

  @doc """
  Return a stable string key for storing this screen's state.

  Implement when the same screen module holds per-user or parameterised state:

      def screen_key(assigns), do: "\#{__MODULE__}:\#{assigns.user_id}"

  Defaults to the module name string.
  """
  @callback screen_key(assigns :: map()) :: String.t()

  @optional_callbacks [handle_event: 3, handle_info: 2, terminate: 2, screen_key: 1]

  defmacro __using__(opts) do
    vsn = Keyword.get(opts, :vsn, 0)
    persist = Keyword.get(opts, :persist, vsn > 0)

    quote do
      @behaviour Mob.Screen
      import Mob.Sigil

      def __mob_vsn__, do: unquote(vsn)
      def __mob_persist__, do: unquote(persist)

      def dump_state(assigns), do: assigns
      def load_state(_vsn, stored), do: stored

      def handle_info(_message, socket), do: {:noreply, socket}
      def terminate(_reason, _socket), do: :ok

      def handle_event(event, _params, _socket) do
        raise "unhandled event #{inspect(event)} in #{inspect(__MODULE__)}. " <>
                "Add a handle_event/3 clause to handle it."
      end

      @before_compile Mob.Screen
      defoverridable dump_state: 1, load_state: 2, handle_info: 2, terminate: 2, handle_event: 3
    end
  end

  defmacro __before_compile__(env) do
    template = Path.rootname(env.file) <> ".mob.heex"

    cond do
      Module.defines?(env.module, {:render, 1}) ->
        quote(do: :ok)

      File.exists?(template) ->
        source =
          template
          |> File.read!()
          |> String.split("\n")
          |> Enum.map_join("\n", &("    " <> &1))

        render_ast =
          Code.string_to_quoted!("""
          def render(assigns) do
            import Mob.Sigil

            ~MOB\"\"\"
          #{source}
            \"\"\"
          end
          """)

        quote do
          @external_resource unquote(template)
          unquote(render_ast)
        end

      true ->
        quote(do: :ok)
    end
  end

  # ── Public API ────────────────────────────────────────────────────────────
  #
  # Navigation and the screen processes live in `Mob.Router`. These delegate, so
  # callers keep the entry points they have always used.

  @doc """
  Start a screen process linked to the calling process.

  `params` is passed as the first argument to `mount/3`.
  """
  @spec start_link(module(), map(), keyword()) :: GenServer.on_start()
  defdelegate start_link(screen_module, params, opts \\ []), to: Mob.Router

  @doc """
  Start a screen as the root UI screen. Calls mount, renders the component tree
  via `Mob.Renderer`, and calls `set_root` on the resulting view.

  This is the main entry point for production use. `start_link/2` is for tests
  (no NIF calls).
  """
  @spec start_root(module(), map(), keyword()) :: GenServer.on_start()
  defdelegate start_root(screen_module, params \\ %{}, opts \\ []), to: Mob.Router

  @doc """
  Dispatch a UI event to the screen process. Returns `:ok` synchronously once
  the event has been processed and the state updated.
  """
  @spec dispatch(pid(), String.t(), map()) :: :ok
  defdelegate dispatch(pid, event, params), to: Mob.Router

  @doc """
  Return the current socket state of a running screen, or `nil` while that
  screen is being restarted.

  Intended for testing and debugging — not for production app logic.
  """
  @spec get_socket(pid()) :: socket() | nil
  defdelegate get_socket(pid), to: Mob.Router

  @doc """
  Return the module of the currently active screen in the navigation stack.
  Intended for testing and debugging.
  """
  @spec get_current_module(pid()) :: module()
  defdelegate get_current_module(pid), to: Mob.Router

  @doc """
  Return the navigation history (list of `{module, socket}` pairs, head = most recent).
  Intended for testing and debugging.
  """
  @spec get_nav_history(pid()) :: [{module(), Mob.Socket.t() | nil}]
  defdelegate get_nav_history(pid), to: Mob.Router

  @doc """
  Return the pid of the process owning the currently active screen.

  Each live screen is its own process since MOB-112; this is how tooling
  reaches the one that is on screen.
  """
  @spec get_screen_pid(GenServer.server()) :: pid()
  defdelegate get_screen_pid(pid), to: Mob.Router
end
