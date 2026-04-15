defmodule Mob.Style do
  @moduledoc """
  Thin wrapper around a props map for named, reusable styles.

  The struct type lets the `~MOB` sigil (and future tooling) distinguish a
  style value from a plain data map. At serialisation time `Mob.Renderer`
  merges a style's props into the node's own props — there is no runtime
  overhead.

  ## Defining styles

      # As a module attribute — compiled to a constant
      @header  %Mob.Style{props: %{text_size: :xl, text_color: :white, background: :primary, padding: 16}}
      @btn     %Mob.Style{props: %{text_size: :lg, text_color: :white, padding: 12}}
      @btn_primary  Mob.Style.put(@btn, :background, :blue_700)
      @btn_danger   Mob.Style.put(@btn, :background, :red_500)

  ## Using styles in a node

      %{
        type: :text,
        props: %{style: @header, text: "Title"},
        children: []
      }

  Inline props override style values, so:

      %{
        type: :text,
        props: %{style: @header, text_size: :base},   # overrides :xl from @header
        children: []
      }

  Token values (`:primary`, `:xl`, `:white`, etc.) are resolved by
  `Mob.Renderer` before JSON serialisation — the native side always
  receives plain integers and floats.
  """

  @enforce_keys []
  defstruct props: %{}

  @type t :: %__MODULE__{props: map()}

  @doc "Merge two styles; keys in `b` win over keys in `a`."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{props: a}, %__MODULE__{props: b}) do
    %__MODULE__{props: Map.merge(a, b)}
  end

  @doc "Return a copy of `style` with `key` set to `value`."
  @spec put(t(), atom(), term()) :: t()
  def put(%__MODULE__{props: p} = s, key, value) do
    %{s | props: Map.put(p, key, value)}
  end
end
