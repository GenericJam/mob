defmodule Mob.Formatter do
  @behaviour Mix.Tasks.Format

  @default_line_length 98

  @impl true
  def features(_opts), do: [sigils: [:MOB], extensions: []]

  @impl true
  def format(contents, opts) do
    line_length = Keyword.get(opts, :line_length, @default_line_length)
    heredoc? = String.starts_with?(contents, "\n")
    trimmed = String.trim(contents)

    case Mob.Sigil.parse_template(trimmed) do
      {:ok, [node], "", _, _, _} ->
        formatted = format_node(node, 0, line_length)
        if heredoc?, do: "\n" <> formatted <> "\n", else: formatted

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
