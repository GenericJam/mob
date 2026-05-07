defmodule Mob.FormatterTest do
  use ExUnit.Case, async: true

  alias Mob.Formatter

  defp fmt(contents, opts \\ []), do: Formatter.format(contents, opts)

  # Elixir strips indentation from heredoc content before passing it to the plugin.
  # The plugin receives trimmed content WITH a trailing "\n" (no leading newline).
  # The plugin must return content + "\n" so Elixir places """ on its own line.
  defp heredoc(inner), do: inner <> "\n"

  describe "features/1" do
    test "handles the MOB sigil" do
      assert {:MOB, _} =
               List.keyfind(Formatter.features([]), :sigils, 0)
               |> then(fn {:sigils, list} -> {:MOB, list} end)

      assert :MOB in Formatter.features([])[:sigils]
    end

    test "does not claim any file extensions" do
      assert Formatter.features([])[:extensions] == []
    end
  end

  describe "self-closing tags" do
    test "no attributes stays on one line" do
      assert fmt("<Text />") == "<Text />"
    end

    test "single string attribute stays on one line" do
      assert fmt(~s(<Text text="Hello" />)) == ~s(<Text text="Hello" />)
    end

    test "single expression attribute stays on one line" do
      assert fmt("<Button on_tap={:ok} />") == "<Button on_tap={:ok} />"
    end

    test "mixed string and expression attributes stays on one line when short" do
      assert fmt(~s(<Button text="Save" on_tap={:ok} />)) ==
               ~s(<Button text="Save" on_tap={:ok} />)
    end

    test "long attribute list wraps to one attr per line" do
      input =
        ~s(<Image source="photo.png" width={200} height={150} corner_radius={8} resizable={true} />)

      expected =
        "<Image\n  source=\"photo.png\"\n  width={200}\n  height={150}\n  corner_radius={8}\n  resizable={true}\n/>"

      assert fmt(input, line_length: 40) == expected
    end

    test "indent is respected when wrapping" do
      input =
        ~s(<Image source="photo.png" width={200} height={150} corner_radius={8} resizable={true} />)

      # When called at indent level 1 (inside a parent), each attr should be indented one extra level.
      # We test this indirectly by wrapping inside an element.
      wrapped_input = "<Column>\n  #{input}\n</Column>"

      result = fmt(heredoc(wrapped_input), line_length: 40)

      # The Image tag should appear at indent level 1 (2 spaces), attrs at level 2 (4 spaces)
      assert result =~ "  <Image\n    source="
    end
  end

  describe "heredoc detection" do
    test "inline content returns no trailing newline" do
      result = fmt("<Text />")
      refute String.ends_with?(result, "\n")
    end

    test "heredoc content (trailing newline) returns trailing newline" do
      result = fmt(heredoc("<Text />"))
      assert String.ends_with?(result, "\n")
    end
  end

  describe "element with children" do
    test "single child is indented" do
      input = heredoc("<Column>\n  <Text text=\"Hello\" />\n</Column>")
      expected = heredoc("<Column>\n  <Text text=\"Hello\" />\n</Column>")
      assert fmt(input) == expected
    end

    test "multiple children each on their own line" do
      input = heredoc("<Column>\n<Text text=\"one\" />\n<Text text=\"two\" />\n</Column>")
      expected = heredoc("<Column>\n  <Text text=\"one\" />\n  <Text text=\"two\" />\n</Column>")
      assert fmt(input) == expected
    end

    test "element with attributes and children" do
      input = heredoc("<Column padding={:space_md}>\n  <Text text=\"Title\" />\n</Column>")
      expected = heredoc("<Column padding={:space_md}>\n  <Text text=\"Title\" />\n</Column>")
      assert fmt(input) == expected
    end

    test "close tag is at same indent as open tag" do
      result = fmt(heredoc("<Column>\n  <Text text=\"Hi\" />\n</Column>"))
      lines = String.split(result, "\n", trim: true)
      [open | _] = lines
      close = List.last(lines)
      assert String.starts_with?(open, "<Column")
      assert close == "</Column>"
    end
  end

  describe "deeply nested structures" do
    test "two levels of nesting" do
      input =
        heredoc(
          """
          <Column>
          <Row>
          <Text text="left" />
          <Text text="right" />
          </Row>
          </Column>
          """
          |> String.trim()
        )

      expected =
        heredoc(
          "<Column>\n  <Row>\n    <Text text=\"left\" />\n    <Text text=\"right\" />\n  </Row>\n</Column>"
        )

      assert fmt(input) == expected
    end

    test "mixed self-closing and container siblings" do
      input =
        heredoc(
          """
          <Column>
          <Text text="label" />
          <Row>
          <Button text="A" />
          <Button text="B" />
          </Row>
          </Column>
          """
          |> String.trim()
        )

      result = fmt(input)

      assert result =~ "  <Text text=\"label\" />"
      assert result =~ "  <Row>"
      assert result =~ "    <Button text=\"A\" />"
      assert result =~ "    <Button text=\"B\" />"
      assert result =~ "  </Row>"
    end
  end

  describe "expression children" do
    test "expression child is indented" do
      input = heredoc("<Column>\n{items}\n</Column>")
      expected = heredoc("<Column>\n  {items}\n</Column>")
      assert fmt(input) == expected
    end

    test "expression child with complex expression passes through unchanged" do
      expr = "Enum.map(items, fn i -> ~MOB(<Text text={i} />) end)"
      input = heredoc("<Column>\n{#{expr}}\n</Column>")
      result = fmt(input)
      assert result =~ "{#{expr}}"
    end

    test "expression child mixed with static child" do
      input = heredoc("<Column>\n<Text text=\"header\" />\n{extra}\n</Column>")
      expected = heredoc("<Column>\n  <Text text=\"header\" />\n  {extra}\n</Column>")
      assert fmt(input) == expected
    end
  end

  describe "idempotency" do
    test "already-formatted inline tag is unchanged" do
      tag = ~s(<Button text="OK" on_tap={:submit} />)
      assert fmt(tag) == tag
    end

    test "already-formatted heredoc is unchanged" do
      doc =
        heredoc(
          "<Column padding={:space_md}>\n  <Text text=\"Title\" />\n  <Button text=\"OK\" />\n</Column>"
        )

      assert fmt(doc) == doc
    end

    test "formatting twice yields the same result" do
      input = heredoc("<Column>\n<Text text=\"a\" />\n<Text text=\"b\" />\n</Column>")
      once = fmt(input)
      twice = fmt(once)
      assert once == twice
    end
  end

  describe "invalid or unparseable content" do
    test "mismatched close tag is corrected to match open tag" do
      # The NimbleParsec parser doesn't validate tag matching (that's build_ast's job).
      # The formatter uses the open tag name for the close tag, normalizing the mismatch.
      bad = heredoc("<Column>\n  <Text text=\"hi\" />\n</Row>")
      assert fmt(bad) == heredoc("<Column>\n  <Text text=\"hi\" />\n</Column>")
    end

    test "not a tag returns content unchanged" do
      bad = "not a tag at all"
      assert fmt(bad) == bad
    end

    test "empty string returns empty string" do
      assert fmt("") == ""
    end
  end

  describe "line_length option" do
    test "default line_length keeps short tags inline" do
      tag = ~s(<Button text="OK" on_tap={:submit} />)
      assert fmt(tag) == tag
    end

    test "very short line_length forces wrapping on short tags" do
      tag = ~s(<Button text="OK" on_tap={:submit} />)
      result = fmt(tag, line_length: 10)
      assert result =~ "\n"
    end
  end
end
