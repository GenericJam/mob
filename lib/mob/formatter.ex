defmodule Mob.Formatter do
  @moduledoc """
  `mix format` plugin for the `~MOB` sigil.

  Add `Mob.Formatter` to your project's `.formatter.exs` and `mix format` will
  automatically normalise every `~MOB` sigil in your codebase alongside all other
  Elixir code:

  ```elixir
  # .formatter.exs
  [
    plugins: [Mob.Formatter],
    inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
  ]
  ```

  ## What it normalises

  - **Consistent indentation** — children are indented 2 spaces per nesting level.
  - **Attribute wrapping** — when a tag's inline attributes would exceed `line_length`,
    each attribute moves to its own line with the closing `/>` or `>` on a separate line.
  - **Expression children** — `{expr}` slots are indented to match their sibling nodes.
  - **Idempotent** — running `mix format` twice produces the same result.

  See the [Tooling & Formatting guide](guides/tooling.html) for before/after examples
  and CI setup instructions.

  ## Configuration

  Respects the standard `line_length` option from `.formatter.exs`:

  ```elixir
  [
    plugins: [Mob.Formatter],
    line_length: 120,
    inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
  ]
  ```

  The default line length is #{@default_line_length} characters.

  ## Pass-through behaviour

  If the `~MOB` template cannot be parsed (e.g. the file is in a mid-edit incomplete
  state), the formatter returns the content unchanged rather than raising. `mix format`
  never breaks a file it cannot fully understand.

  Mismatched open/close tag names (e.g. `<Column>...</Row>`) are silently corrected to
  use the open tag name. The `~MOB` sigil itself raises a `CompileError` at compile
  time for mismatched tags, so the formatted file will still surface the error on the
  next `mix compile`.
  """

  @behaviour Mix.Tasks.Format

  @default_line_length 98

  @impl true
  def features(_opts), do: [sigils: [:MOB], extensions: []]

  @impl true
  def format(contents, opts) do
    line_length = Keyword.get(opts, :line_length, @default_line_length)
    heredoc? = opts[:opening_delimiter] == ~s(""") or String.ends_with?(contents, "\n")
    trimmed = String.trim(contents)

    case Mob.Sigil.parse_template(trimmed) do
      {:ok, [node], "", _, _, _} ->
        formatted = format_node(node, 0, line_length)
        if heredoc?, do: formatted <> "\n", else: formatted

      _ ->
        contents
    end
  end

  defp format_node({:self_closing, [tag | attrs]}, indent, line_length) do
    indent_str = String.duplicate("  ", indent)
    inline_attrs = format_attrs_inline(attrs)

    inline =
      if inline_attrs == "",
        do: "#{indent_str}<#{tag} />",
        else: "#{indent_str}<#{tag} #{inline_attrs} />"

    if String.length(inline) <= line_length do
      inline
    else
      attr_indent = String.duplicate("  ", indent + 1)
      multi_attrs = Enum.map_join(attrs, "\n", &(attr_indent <> format_attr(&1)))
      "#{indent_str}<#{tag}\n#{multi_attrs}\n#{indent_str}/>"
    end
  end

  defp format_node({:element, parts}, indent, line_length) do
    {open_part, rest} = List.keytake(parts, :open_part, 0)
    {_close, children_parts} = List.keytake(rest, :close_tag, 0)
    {:open_part, [tag | attrs]} = open_part

    indent_str = String.duplicate("  ", indent)
    inline_attrs = format_attrs_inline(attrs)

    open_inline =
      if inline_attrs == "",
        do: "#{indent_str}<#{tag}>",
        else: "#{indent_str}<#{tag} #{inline_attrs}>"

    open_tag =
      if String.length(open_inline) <= line_length do
        open_inline
      else
        attr_indent = String.duplicate("  ", indent + 1)
        multi_attrs = Enum.map_join(attrs, "\n", &(attr_indent <> format_attr(&1)))
        "#{indent_str}<#{tag}\n#{multi_attrs}\n#{indent_str}>"
      end

    children_str =
      children_parts
      |> Enum.map(&format_child(&1, indent + 1, line_length))
      |> Enum.join("\n")

    "#{open_tag}\n#{children_str}\n#{indent_str}</#{tag}>"
  end

  defp format_child({:self_closing, _} = node, indent, line_length),
    do: format_node(node, indent, line_length)

  defp format_child({:element, _} = node, indent, line_length),
    do: format_node(node, indent, line_length)

  defp format_child({:expr_child, [expr]}, indent, _line_length),
    do: "#{String.duplicate("  ", indent)}{#{expr}}"

  defp format_attrs_inline(attrs), do: Enum.map_join(attrs, " ", &format_attr/1)

  defp format_attr({:attr, [name, {:string_val, [val]}]}), do: ~s(#{name}="#{val}")
  defp format_attr({:attr, [name, {:expr_val, [expr]}]}), do: "#{name}={#{expr}}"
end
