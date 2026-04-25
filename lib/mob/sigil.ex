defmodule Mob.Sigil do
  @moduledoc """
  The `~MOB` sigil for declarative native UI.

  Compiles a tag template to a `Mob.Renderer`-compatible node map **at compile
  time** using NimbleParsec. Expressions in `{...}` are evaluated in the
  caller's scope at runtime.

  Use `~MOB(...)` for single nodes or `~MOB\"""...\"""` for nested layouts.

  ## Examples

      import Mob.Sigil

      # Self-closing
      ~MOB(<Text text="Hello" />)
      #=> %{type: :text, props: %{text: "Hello"}, children: []}

      # Nested layout
      ~MOB\"""
      <Column padding={:space_md}>
        <Text text="Title" text_size={:xl} />
        <Button text="OK" on_tap={{self(), :ok}} />
      </Column>
      \"""

      # Expression child — inject any node map or list of maps
      ~MOB\"""
      <Column>
        {Enum.map(items, fn i -> ~MOB(<Text text={i} />) end)}
      </Column>
      \"""

  ## Tag whitelist

  Tags are validated against `priv/tags/ios.txt` and `priv/tags/android.txt` at
  compile time. Unknown tags emit a warning but still pass through — the type
  atom is derived by converting PascalCase to snake_case (e.g. `TabBar` →
  `:tab_bar`). This allows new native tags to be used before the whitelist is
  updated.
  """

  # ── Whitelist ────────────────────────────────────────────────────────────────

  @known_tags (
                ios_file = Application.app_dir(:mob, "priv/tags/ios.txt")
                android_file = Application.app_dir(:mob, "priv/tags/android.txt")

                parse_tags = fn file ->
                  if File.exists?(file) do
                    file
                    |> File.read!()
                    |> String.split("\n", trim: true)
                    |> Enum.reject(&String.starts_with?(&1, "#"))
                    |> MapSet.new()
                  else
                    MapSet.new()
                  end
                end

                ios_tags = parse_tags.(ios_file)
                android_tags = parse_tags.(android_file)

                %{
                  ios: ios_tags,
                  android: android_tags,
                  both: MapSet.union(ios_tags, android_tags)
                }
              )

  # ── Parser (NimbleParsec) ────────────────────────────────────────────────────

  import NimbleParsec

  whitespace = ascii_string([?\s, ?\t, ?\n, ?\r], min: 1)
  opt_ws = optional(whitespace)

  # Tag name: starts with uppercase letter
  tag_name =
    ascii_char([?A..?Z])
    |> ascii_string([?a..?z, ?A..?Z, ?0..?9, ?.], min: 0)
    |> reduce({List, :to_string, []})
    |> label("tag name starting with uppercase letter")

  # Attribute name
  attr_name =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
    |> reduce({List, :to_string, []})
    |> label("attribute name")

  # String attribute value: "..."
  string_value =
    ignore(ascii_char([?"]))
    |> ascii_string([not: ?"], min: 0)
    |> ignore(ascii_char([?"]))
    |> tag(:string_val)

  # Expression attribute value: {...} with balanced brace support
  # Uses parsec(:brace_content) — defined below via defparsec
  expr_value =
    ignore(ascii_char([?{]))
    |> parsec(:brace_content)
    |> ignore(ascii_char([?}]))
    |> tag(:expr_val)

  attr_value = choice([string_value, expr_value])

  # Single attribute: name="val" or name={expr}
  attribute =
    opt_ws
    |> ignore()
    |> concat(attr_name)
    |> ignore(ascii_char([?=]))
    |> concat(attr_value)
    |> tag(:attr)

  attributes = repeat(attribute)

  # Expression child: {some_expr} with balanced brace support
  expr_child =
    ignore(ascii_char([?{]))
    |> parsec(:brace_content)
    |> ignore(ascii_char([?}]))
    |> tag(:expr_child)

  # Self-closing tag: <Tag attrs />
  self_closing =
    ignore(ascii_char([?<]))
    |> concat(tag_name)
    |> concat(attributes)
    |> ignore(opt_ws)
    |> ignore(string("/>"))
    |> tag(:self_closing)

  # Close tag: </Tag>
  close_tag =
    ignore(string("</"))
    |> concat(tag_name)
    |> ignore(opt_ws)
    |> ignore(ascii_char([?>]))
    |> tag(:close_tag)

  # A child is either a nested node (self-closing or open) or an expression slot
  # We use parsec/1 for recursion into node/0 defined below.
  child =
    choice([
      parsec(:node),
      expr_child
    ])

  children = repeat(ignore(opt_ws) |> concat(child))

  # Full element: <Tag attrs>children</Tag>
  element =
    ignore(ascii_char([?<]))
    |> concat(tag_name)
    |> concat(attributes)
    |> ignore(opt_ws)
    |> ignore(ascii_char([?>]))
    |> tag(:open_part)
    |> concat(children)
    |> ignore(opt_ws)
    |> concat(close_tag)
    |> tag(:element)

  # Balanced brace content: captures everything between an outer { } pair,
  # preserving inner { } pairs recursively. Returns a single joined string.
  # Used by expr_value and expr_child so that {%{a: 1}} and {fn -> ... end} work.
  defparsec(
    :brace_content,
    repeat(
      choice([
        ascii_string([not: ?{, not: ?}], min: 1),
        string("{")
        |> parsec(:brace_content)
        |> string("}")
        |> reduce({Enum, :join, [""]})
      ])
    )
    |> reduce({Enum, :join, [""]})
  )

  defparsec(
    :node,
    choice([
      self_closing,
      element
    ])
  )

  defparsec(
    :parse_template,
    ignore(opt_ws)
    |> parsec(:node)
    |> ignore(opt_ws)
    |> eos()
  )

  # ── Macro ────────────────────────────────────────────────────────────────────

  @doc """
  Compiles a `~MOB(...)` or `~MOB\"""...\"""` template into a native UI node map.
  Parsed at compile time; `{expr}` values evaluated at runtime in the caller's scope.
  """
  defmacro sigil_MOB({:<<>>, _meta, [template]}, _modifiers) when is_binary(template) do
    caller = __CALLER__

    case parse_template(String.trim(template)) do
      {:ok, [node], "", _, _, _} ->
        build_ast(node, caller)

      {:ok, _, rest, _, _, _} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "~MOB: unexpected input near: #{inspect(String.slice(rest, 0, 40))}"

      {:error, reason, rest, _, _, _} ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "~MOB: #{reason} near: #{inspect(String.slice(rest, 0, 40))}"
    end
  end

  # ── AST builder ─────────────────────────────────────────────────────────────

  defp build_ast({:self_closing, parts}, caller) do
    {tag, attrs} = split_tag_attrs(parts)
    type = resolve_type(tag, caller)
    props = build_props_ast(attrs, caller)
    quote do: %{type: unquote(type), props: unquote(props), children: []}
  end

  defp build_ast({:element, parts}, caller) do
    # parts: [{:open_part, [tag, ...attrs]}, ...children..., {:close_tag, [close_tag]}]
    {open_part, rest} = List.keytake(parts, :open_part, 0)
    {close_tag, rest2} = List.keytake(rest, :close_tag, 0)

    {:open_part, open_parts} = open_part
    {:close_tag, [close_name]} = close_tag

    {tag, attrs} = split_tag_attrs(open_parts)

    unless tag == close_name do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "~MOB: mismatched tags <#{tag}> ... </#{close_name}>"
    end

    type = resolve_type(tag, caller)
    props = build_props_ast(attrs, caller)
    children_ast = build_children_ast(rest2, caller)

    quote do: %{type: unquote(type), props: unquote(props), children: unquote(children_ast)}
  end

  defp split_tag_attrs([tag | attrs]), do: {tag, attrs}

  defp build_props_ast(attrs, caller) do
    pairs =
      Enum.map(attrs, fn {:attr, [name, value_tag]} ->
        key = String.to_atom(name)
        val = build_value_ast(value_tag, caller)
        {key, val}
      end)

    {:%{}, [], pairs}
  end

  defp build_value_ast({:string_val, [str]}, _caller), do: str

  defp build_value_ast({:expr_val, [expr_str]}, caller) do
    Code.string_to_quoted!(String.trim(expr_str), file: caller.file, line: caller.line)
  end

  defp build_children_ast(children, caller) do
    child_asts =
      Enum.map(children, fn
        {:expr_child, [expr_str]} ->
          quoted =
            Code.string_to_quoted!(String.trim(expr_str), file: caller.file, line: caller.line)

          quote do
            case unquote(quoted) do
              list when is_list(list) -> list
              node -> [node]
            end
          end

        node_tuple ->
          ast = build_ast(node_tuple, caller)
          quote do: [unquote(ast)]
      end)

    quote do: List.flatten(unquote(child_asts))
  end

  defp resolve_type(tag, caller) do
    atom = tag |> Macro.underscore() |> String.to_atom()

    unless MapSet.member?(@known_tags.both, tag) do
      ios_only =
        MapSet.member?(@known_tags.ios, tag) and not MapSet.member?(@known_tags.android, tag)

      android_only =
        MapSet.member?(@known_tags.android, tag) and not MapSet.member?(@known_tags.ios, tag)

      msg =
        cond do
          ios_only -> "~MOB: <#{tag}> is iOS-only — not supported on Android"
          android_only -> "~MOB: <#{tag}> is Android-only — not supported on iOS"
          true -> "~MOB: <#{tag}> is not in the Mob tag whitelist — pass-through as :#{atom}"
        end

      IO.warn(msg, Macro.Env.stacktrace(caller))
    end

    atom
  end
end
