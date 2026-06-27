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

  ## Assigns shorthand

  Inside a `{...}` expression, `@foo` rewrites to `assigns.foo` (matching
  Phoenix HEEx), so a `render(assigns)` body reads cleanly:

      ~MOB(<Text text={@title} />)   # same as text={assigns.title}

  ## Control attributes — `:if` and `:for`

  Two LiveView-style directives wrap an element without extra ceremony.
  Both take a `{expr}` value and may read `@assigns`.

      # Conditional — omitted entirely when the expression is falsy
      ~MOB(<Badge text="New" :if={@unread > 0} />)

      # Comprehension — one element per item; splices into the parent
      ~MOB\"""
      <Column>
        <Row :for={user <- @users}>
          <Text text={user.name} />
        </Row>
      </Column>
      \"""

  Combine them — `:if` then acts as a comprehension filter (an element is
  produced only for items where the condition holds):

      <Text text={n} :for={n <- @nums} :if={rem(n, 2) == 0} />

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

  # Attribute name. An optional leading `:` marks a control attribute
  # (`:if`, `:for`) — LiveView-style directives handled specially by the AST
  # builder rather than emitted as a prop.
  attr_name =
    optional(ascii_char([?:]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> ascii_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
    |> reduce({List, :to_string, []})
    |> label("attribute name")

  # String attribute value: "..."
  #
  # `utf8_string/2` (not `ascii_string/2`) so non-ASCII bytes in the
  # template source — em-dash, en-dash, smart quotes, accented letters,
  # emoji — are matched as UTF-8 codepoints and emitted as UTF-8 binary
  # segments. `ascii_string([not: ?"])` accepts those bytes but its
  # `integer` body re-encodes each one as a Latin-1 codepoint then UTF-8
  # (so `–` E2 80 93 comes out as C3 A2 C2 80 C2 93 — double-encoded).
  string_value =
    ignore(ascii_char([?"]))
    |> utf8_string([not: ?"], min: 0)
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
  # `utf8_string/2` (not `ascii_string/2`) — same reason as `string_value`
  # above: brace content can be arbitrary Elixir source including literal
  # non-ASCII strings, and `ascii_string` would double-encode those bytes
  # before they reach `Code.string_to_quoted!/2`.
  defparsec(
    :brace_content,
    repeat(
      choice([
        utf8_string([not: ?{, not: ?}], min: 1),
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
    {control, attrs} = split_control_attrs(attrs, caller)
    type = resolve_type(tag, caller)
    props = build_props_ast(attrs, caller)
    node = quote do: %{type: unquote(type), props: unquote(props), children: []}
    wrap_control(node, control, caller)
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

    {control, attrs} = split_control_attrs(attrs, caller)
    type = resolve_type(tag, caller)
    props = build_props_ast(attrs, caller)
    children_ast = build_children_ast(rest2, caller)

    node =
      quote do: %{type: unquote(type), props: unquote(props), children: unquote(children_ast)}

    wrap_control(node, control, caller)
  end

  defp split_tag_attrs([tag | attrs]), do: {tag, attrs}

  # Partition control attributes (`:if`, `:for`) out of the normal attr list.
  # Returns `{%{if: value_tag, for: value_tag}, remaining_attrs}`. Control
  # attrs never become props; they wrap the node in `if`/`for` instead.
  defp split_control_attrs(attrs, caller) do
    {control, rev_normal} =
      Enum.reduce(attrs, {%{}, []}, fn
        {:attr, [":if", value_tag]}, {control, normal} ->
          {Map.put(control, :if, value_tag), normal}

        {:attr, [":for", value_tag]}, {control, normal} ->
          {Map.put(control, :for, value_tag), normal}

        {:attr, [":" <> bad, _value]}, _acc ->
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description:
              "~MOB: unknown control attribute :#{bad} (only :if and :for are supported)"

        attr, {control, normal} ->
          {control, [attr | normal]}
      end)

    {control, Enum.reverse(rev_normal)}
  end

  # Wrap a node's AST in a `:for` comprehension and/or `:if` guard. When both
  # are present, `:if` acts as a comprehension filter (LiveView semantics):
  # the element is produced for each item where the condition holds. A bare
  # `:if` that fails yields `nil`, which `wrap_child/1` drops from its parent.
  defp wrap_control(node_ast, control, caller) do
    # Branch on attr *presence* (the value-tag), never on the parsed expr —
    # `:if={false}` parses to the literal `false`, which would otherwise
    # short-circuit a truthiness check and skip the wrapping entirely.
    cond do
      control[:for] && control[:if] ->
        for_ast = parse_control_expr(:for, control[:for], caller)
        if_ast = parse_control_expr(:if, control[:if], caller)
        quote do: for(unquote(for_ast), unquote(if_ast), do: unquote(node_ast))

      control[:for] ->
        for_ast = parse_control_expr(:for, control[:for], caller)
        quote do: for(unquote(for_ast), do: unquote(node_ast))

      control[:if] ->
        if_ast = parse_control_expr(:if, control[:if], caller)
        quote do: if(unquote(if_ast), do: unquote(node_ast))

      true ->
        node_ast
    end
  end

  defp parse_control_expr(_which, {:expr_val, [expr_str]}, caller),
    do: parse_expr(expr_str, caller)

  defp parse_control_expr(which, {:string_val, _}, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "~MOB: :#{which} requires a {expr} value, e.g. :#{which}={...}"
  end

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

  defp build_value_ast({:expr_val, [expr_str]}, caller), do: parse_expr(expr_str, caller)

  # Parse a `{expr}` source string into an AST, expanding LiveView-style
  # `@foo` references into `assigns.foo`. Applies to attribute values,
  # `{expr}` children, and `:if`/`:for` control expressions alike.
  defp parse_expr(expr_str, caller) do
    expr_str
    |> String.trim()
    |> Code.string_to_quoted!(file: caller.file, line: caller.line)
    |> expand_assigns()
  end

  # Rewrite every `@name` (the unary `@` operator on a bare identifier) to
  # `assigns.name`, mirroring HEEx. Nested forms like `@user.name` rewrite
  # too, since prewalk reaches the inner `@user` node first.
  defp expand_assigns(ast) do
    Macro.prewalk(ast, fn
      {:@, _meta, [{name, _, ctx}]} when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) ->
        # Build `assigns.name` with a nil-context `assigns` var so it
        # resolves to the caller's binding (same as a literal `assigns`
        # parsed from source), not a hygienic Mob.Sigil-scoped variable.
        # `no_parens: true` marks it as map-field access, not `assigns.name()`.
        {{:., [], [Macro.var(:assigns, nil), name]}, [no_parens: true], []}

      other ->
        other
    end)
  end

  defp build_children_ast(children, caller) do
    child_asts =
      Enum.map(children, fn
        {:expr_child, [expr_str]} ->
          quoted = parse_expr(expr_str, caller)

          # Emit a call to `wrap_child/1` rather than an inline `case`.
          # The inline version generates a `case` per call site whose
          # `is_list(list)` clause is type-narrowed to "unreachable"
          # whenever the user's expression has a static-shape return
          # (e.g. `nav_button("Foo", :bar)` is always a map). The
          # warning is correct in isolation but the multi-shape
          # tolerance is the WHOLE POINT of {expr} children — users
          # can write `Enum.map(items, &row/1)` and get list-flattened
          # behaviour. Dispatching via a helper hides the
          # type-narrowing from the per-call-site warning while
          # preserving both shapes' runtime behaviour.
          quote do: Mob.Sigil.wrap_child(unquote(quoted))

        node_tuple ->
          # A node may now be a bare map, a `:for` list, or a `:if` nil after
          # control-attr wrapping. Route it through wrap_child/1 so all three
          # normalize to a list before the surrounding List.flatten.
          ast = build_ast(node_tuple, caller)
          quote do: Mob.Sigil.wrap_child(unquote(ast))
      end)

    quote do: List.flatten(unquote(child_asts))
  end

  @doc """
  Normalizes a child's value to a list of UI-node maps for the
  surrounding sigil. Single nodes wrap into a one-element list; lists
  pass through; `nil` (a `:if` that didn't render) drops to `[]`.
  Public so the sigil-generated AST can call it by FQ name; not part
  of the application API.
  """
  @spec wrap_child(list() | map() | nil) :: list()
  def wrap_child(list) when is_list(list), do: list
  def wrap_child(nil), do: []
  def wrap_child(node), do: [node]

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
