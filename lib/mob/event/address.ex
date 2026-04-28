defmodule Mob.Event.Address do
  @moduledoc """
  Canonical address for an event in the Mob view tree.

  An address identifies *where* a widget lives (`screen` and `component_path`)
  and *what* fired (`widget`, `id`, `instance`). It also carries `render_id`
  so handlers can detect events from prior render generations.

  See `guides/event_model.md` for the full event model.

  ## Example

      %Mob.Event.Address{
        screen:         MyApp.CheckoutScreen,
        component_path: [:checkout_form],
        widget:         :button,
        id:             :submit,
        instance:       nil,
        render_id:      42
      }
  """

  @typedoc """
  Anything pattern-matchable that survives serialisation. Atoms are best for
  compile-time-known IDs; binaries for data-derived ones (DB IDs, UUIDs);
  integers/tuples for indices and compound keys.

  Floats, maps, and lists are technically allowed but discouraged: floats have
  fuzzy equality, maps and lists are heavy to hash on every event.

  Pids, refs, and funs are explicitly forbidden — they don't survive
  serialisation and can't be the basis of a stable address across re-renders.
  """
  @type id :: atom() | binary() | integer() | float() | tuple() | map() | list()

  @type t :: %__MODULE__{
          screen: atom() | pid(),
          component_path: [id()],
          widget: atom(),
          id: id(),
          instance: id() | nil,
          render_id: pos_integer()
        }

  @enforce_keys [:screen, :widget, :id]
  defstruct screen: nil,
            component_path: [],
            widget: nil,
            id: nil,
            instance: nil,
            render_id: 1

  @doc """
  Build an address. `screen`, `widget`, and `id` are required. The rest take
  reasonable defaults.

      iex> Mob.Event.Address.new(screen: MyScreen, widget: :button, id: :save)
      %Mob.Event.Address{screen: MyScreen, widget: :button, id: :save, component_path: [], instance: nil, render_id: 1}

      iex> Mob.Event.Address.new(screen: MyScreen, widget: :list, id: :contacts, instance: 47, render_id: 12)
      %Mob.Event.Address{screen: MyScreen, widget: :list, id: :contacts, instance: 47, component_path: [], render_id: 12}
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    screen = Keyword.fetch!(opts, :screen)
    widget = Keyword.fetch!(opts, :widget)
    id = Keyword.fetch!(opts, :id)

    %__MODULE__{
      screen: screen,
      component_path: Keyword.get(opts, :component_path, []),
      widget: widget,
      id: id,
      instance: Keyword.get(opts, :instance),
      render_id: Keyword.get(opts, :render_id, 1)
    }
  end

  @doc """
  Validate that `id` is one of the supported types. Returns `:ok` or
  `{:error, reason}`.

  Used by `Mob.Renderer` and `Mob.Event` to fail fast when an obviously-bad
  ID is passed (e.g. a pid, a function, or an undefined value).

      iex> Mob.Event.Address.validate_id(:save)
      :ok

      iex> Mob.Event.Address.validate_id("contact:42")
      :ok

      iex> Mob.Event.Address.validate_id(42)
      :ok

      iex> Mob.Event.Address.validate_id(self())
      {:error, :pid_not_allowed}

      iex> Mob.Event.Address.validate_id(nil)
      {:error, :nil_not_allowed}
  """
  @spec validate_id(term()) :: :ok | {:error, atom()}
  def validate_id(id) when is_atom(id) and not is_nil(id), do: :ok
  def validate_id(id) when is_binary(id), do: :ok
  def validate_id(id) when is_integer(id), do: :ok
  def validate_id(id) when is_float(id), do: :ok
  def validate_id(id) when is_tuple(id), do: :ok
  def validate_id(id) when is_list(id), do: :ok
  def validate_id(id) when is_map(id) and not is_struct(id), do: :ok
  def validate_id(nil), do: {:error, :nil_not_allowed}
  def validate_id(id) when is_pid(id), do: {:error, :pid_not_allowed}
  def validate_id(id) when is_reference(id), do: {:error, :reference_not_allowed}
  def validate_id(id) when is_function(id), do: {:error, :function_not_allowed}
  def validate_id(id) when is_port(id), do: {:error, :port_not_allowed}
  def validate_id(_), do: {:error, :unsupported_type}

  @doc """
  True if the address points to the same logical widget as `other`. Ignores
  `render_id` — useful for "is this another tap on the same button?" checks.
  """
  @spec same_widget?(t(), t()) :: boolean()
  def same_widget?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.screen == b.screen and
      a.component_path == b.component_path and
      a.widget == b.widget and
      a.id == b.id and
      a.instance == b.instance
  end

  @doc """
  True if `addr.render_id` matches `current_render_id`.

  Use to detect stale events arriving after a re-render.
  """
  @spec current?(t(), pos_integer()) :: boolean()
  def current?(%__MODULE__{render_id: rid}, current_render_id)
      when is_integer(current_render_id) do
    rid == current_render_id
  end

  @doc """
  Bump the render id on an address (e.g. when re-registering a widget after a
  render). Returns a new address; original is unchanged.
  """
  @spec with_render_id(t(), pos_integer()) :: t()
  def with_render_id(%__MODULE__{} = addr, render_id)
      when is_integer(render_id) and render_id > 0 do
    %{addr | render_id: render_id}
  end

  @doc """
  Format an address as a short, human-readable string for logs.

      iex> Mob.Event.Address.to_string(%Mob.Event.Address{screen: MyScreen, widget: :button, id: :save})
      "MyScreen→button#save"

      iex> Mob.Event.Address.to_string(%Mob.Event.Address{screen: MyScreen, component_path: [:form], widget: :text_field, id: :email})
      "MyScreen/form→text_field#email"

      iex> Mob.Event.Address.to_string(%Mob.Event.Address{screen: MyScreen, widget: :list, id: :contacts, instance: 47})
      "MyScreen→list#contacts[47]"
  """
  @spec to_string(t()) :: binary()
  def to_string(%__MODULE__{} = a) do
    screen = format_screen(a.screen)
    path = if a.component_path == [], do: "", else: "/" <> Enum.map_join(a.component_path, "/", &format_id/1)
    instance = if is_nil(a.instance), do: "", else: "[" <> format_id(a.instance) <> "]"
    "#{screen}#{path}→#{a.widget}##{format_id(a.id)}#{instance}"
  end

  defp format_screen(s) when is_atom(s) do
    s
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp format_screen(s), do: inspect(s)

  defp format_id(id) when is_atom(id), do: Atom.to_string(id)
  defp format_id(id) when is_binary(id), do: id
  defp format_id(id), do: inspect(id)
end

defimpl String.Chars, for: Mob.Event.Address do
  def to_string(addr), do: Mob.Event.Address.to_string(addr)
end

defimpl Inspect, for: Mob.Event.Address do
  import Inspect.Algebra

  @spec inspect(Mob.Event.Address.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(addr, _opts) do
    concat([
      "#Mob.Event.Address<",
      Mob.Event.Address.to_string(addr),
      "@",
      Integer.to_string(addr.render_id),
      ">"
    ])
  end
end
