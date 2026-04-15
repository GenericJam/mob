defmodule Mob.Sigil do
  @moduledoc """
  The `~MOB` sigil for declarative native UI.

  Compiles a tag template to a `Mob.Renderer`-compatible node map **at compile
  time**. Expressions in `{...}` are evaluated in the caller's scope at runtime.

  Use `()` or `[]` delimiters — `~MOB` is an uppercase sigil so quote chars
  inside do not need escaping.

  ## Examples

      import Mob.Sigil

      # Static attribute
      ~MOB(<Text text="Hello" />)
      #=> %{type: :text, props: %{text: "Hello"}, children: []}

      # Expression attribute — evaluated in the caller's scope
      name = "World"
      ~MOB(<Text text={name} />)
      #=> %{type: :text, props: %{text: "World"}, children: []}

      # Mixing sigil output and component functions is fine — same map format
      [~MOB(<Text text="a" />), Mob.UI.text(text: "b")]

  ## Available components

  | Tag      | Renderer type |
  |----------|---------------|
  | Text     | `:text`       |
  | Button   | `:button`     |
  | Column   | `:column`     |
  | Row      | `:row`        |
  | Scroll   | `:scroll`     |

  > **Note**: Only self-closing tags (`<Tag ... />`) are supported at this
  > stage. Container tags (`<Column>...</Column>`) will be added when layout
  > nesting is built out.
  """

  @known_tags %{
    "Text"   => :text,
    "Button" => :button,
    "Column" => :column,
    "Row"    => :row,
    "Scroll" => :scroll
  }

  @doc """
  Compiles a `~MOB(...)` template into a native UI node map.

  The template is parsed at **compile time**; `{expr}` attribute values are
  evaluated at runtime in the caller's scope.
  """
  defmacro sigil_MOB({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    compile(String.trim(template), __CALLER__)
  end

  # ── Compiler ─────────────────────────────────────────────────────────────────

  defp compile(template, caller) do
    case parse_self_closing(template) do
      {:ok, tag_name, attrs} ->
        type      = resolve_tag!(tag_name, caller)
        props_ast = attrs_to_ast(attrs, caller)
        quote do
          %{type: unquote(type), props: unquote(props_ast), children: []}
        end

      {:error, reason} ->
        raise CompileError,
          file:        caller.file,
          line:        caller.line,
          description: "~MOB: #{reason}"
    end
  end

  # ── Parsing ───────────────────────────────────────────────────────────────────

  # Matches:  <TagName attr1="val" attr2={expr} ... />
  @self_closing_re ~r/^<([A-Z][a-zA-Z0-9]*)(\s[^>]*)?\s*\/>$/s

  defp parse_self_closing(template) do
    case Regex.run(@self_closing_re, template) do
      [_, tag]        -> {:ok, tag, []}
      [_, tag, attrs] -> {:ok, tag, parse_attrs(String.trim(attrs))}
      nil ->
        {:error,
         "expected a self-closing tag, e.g. <Text text=\"hello\" />, " <>
           "got: #{inspect(template)}"}
    end
  end

  # Two separate patterns — avoids alternation-group ambiguity with Regex.scan.
  @string_attr_re ~r/(\w+)="([^"]*)"/
  @expr_attr_re   ~r/(\w+)=\{([^}]*)\}/

  defp parse_attrs(""), do: []
  defp parse_attrs(str) do
    literals =
      @string_attr_re
      |> Regex.scan(str)
      |> Enum.map(fn [_, name, value] -> {String.to_atom(name), {:literal, value}} end)

    exprs =
      @expr_attr_re
      |> Regex.scan(str)
      |> Enum.map(fn [_, name, expr_s] -> {String.to_atom(name), {:expr, String.trim(expr_s)}} end)

    # Merge by position in the original string so prop order is preserved.
    (literals ++ exprs)
    |> Enum.sort_by(fn {name, _} ->
      case Regex.run(~r/#{Atom.to_string(name)}=/, str, return: :index) do
        [{pos, _}] -> pos
        _ -> 999
      end
    end)
  end

  defp resolve_tag!(tag_name, caller) do
    case Map.fetch(@known_tags, tag_name) do
      {:ok, type} ->
        type

      :error ->
        known = @known_tags |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        raise CompileError,
          file:        caller.file,
          line:        caller.line,
          description: "~MOB: unknown component <#{tag_name}>. Known: #{known}"
    end
  end

  defp attrs_to_ast(attrs, caller) do
    pairs =
      Enum.map(attrs, fn
        {name, {:literal, value}} ->
          {name, value}

        {name, {:expr, expr_str}} ->
          quoted = Code.string_to_quoted!(expr_str, file: caller.file, line: caller.line)
          {name, quoted}
      end)

    {:%{}, [], pairs}
  end
end
