defmodule Mob.Test.NativeSource do
  @moduledoc """
  Strips comments from Swift and Objective-C sources so the native assertions
  in the test suite match on code, not on prose.

  These tests read `ios/*.swift` and `ios/*.m` and assert that particular calls
  are present. Without stripping, a `=~` assertion is satisfied by the very
  comment that describes the call — including a comment describing code that
  was deleted, which is a false pass in the direction that matters.
  """

  @doc """
  Return `source` with every comment removed and everything else byte-for-byte
  intact.

  Newlines inside comments are kept so line numbers do not shift.

  Pass `:objc` for `.m` sources, where block comments do NOT nest. Defaults to
  `:swift`, where they do.

  Raises if the scan does not end back in code. Every way this scanner can go
  wrong — an unterminated literal, a quoting form it does not know, a `/*`
  inside a comment — leaves it stuck in some other state, and from there it
  reports comments as code (a false pass) or eats code as comment (a false
  failure whose message points at the assertion rather than the cause). Failing
  loudly is the only way those stay visible.
  """
  @spec code_only(binary(), :swift | :objc) :: binary()
  def code_only(source, language \\ :swift) do
    case scan(source, :code, [], language) do
      {:code, out} ->
        out

      {state, _} ->
        raise """
        native source scan ended in #{inspect(state)}, not :code.

        The scanner is stuck, so its output cannot be trusted. Usually an
        unterminated string or block comment, or a `/*` inside a comment in a
        Swift file (block comments nest there, so it opens a second level).
        """
    end
  end

  @doc """
  The text between `from` and `to`, exclusive.

  Raises if either marker is missing, rather than returning a silently empty
  region that every subsequent assertion would then match nothing against.
  """
  @spec region(binary(), binary(), binary()) :: binary()
  def region(source, from, to) do
    unless String.contains?(source, from), do: raise("region start not found: #{inspect(from)}")
    [_, rest] = String.split(source, from, parts: 2)

    unless String.contains?(rest, to), do: raise("region end not found: #{inspect(to)}")
    [body | _] = String.split(rest, to, parts: 2)
    body
  end

  @doc """
  Byte offset of `needle` in `hay`.

  For asserting that one construct precedes another — a guard before the write
  it protects, say — which a pair of `=~` assertions cannot express.
  """
  @spec index_of(binary(), binary()) :: non_neg_integer()
  def index_of(hay, needle) do
    case :binary.match(hay, needle) do
      {i, _} -> i
      :nomatch -> raise "expected to find #{inspect(needle)}"
    end
  end

  # Scans the whole file as one binary, carrying string and block-comment state
  # ACROSS lines. A per-line scanner reset `in_string` at every newline, which
  # breaks on Swift's multi-line `"""` literals — MobGpuView.swift embeds MSL
  # shader source that way, and a `//` inside it was truncated as if it were a
  # comment. It also never recognised `/* */`, so commented-out code satisfied a
  # `=~` assertion: a false pass, the inverse of the bug this replaced.
  defp scan(<<>>, state, acc, _lang),
    do: {simplify(state), acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp scan(<<"\\", c::utf8, rest::binary>>, :string, acc, lang),
    do: scan(rest, :string, [<<c::utf8>>, "\\" | acc], lang)

  defp scan(<<"\"\"\"", rest::binary>>, :code, acc, lang),
    do: scan(rest, :multiline, ["\"\"\"" | acc], lang)

  defp scan(<<"\"\"\"", rest::binary>>, :multiline, acc, lang),
    do: scan(rest, :code, ["\"\"\"" | acc], lang)

  defp scan(<<c::utf8, rest::binary>>, :multiline, acc, lang),
    do: scan(rest, :multiline, [<<c::utf8>> | acc], lang)

  defp scan(<<"#\"", rest::binary>>, :code, acc, lang),
    do: scan(rest, :raw_string, ["#\"" | acc], lang)

  defp scan(<<"\"#", rest::binary>>, :raw_string, acc, lang),
    do: scan(rest, :code, ["\"#" | acc], lang)

  defp scan(<<c::utf8, rest::binary>>, :raw_string, acc, lang),
    do: scan(rest, :raw_string, [<<c::utf8>> | acc], lang)

  defp scan(<<"\"", rest::binary>>, :code, acc, lang), do: scan(rest, :string, ["\"" | acc], lang)
  defp scan(<<"\"", rest::binary>>, :string, acc, lang), do: scan(rest, :code, ["\"" | acc], lang)

  defp scan(<<c::utf8, rest::binary>>, :string, acc, lang),
    do: scan(rest, :string, [<<c::utf8>> | acc], lang)

  # Objective-C character literals. No file the tests currently read contains
  # `'"'` — `ios/mob_beam.m` has char literals but nothing asserts against it —
  # so this is defensive, not a fix for a live break. It is cheap and the
  # failure it prevents is silent: one quoted quote flips the scanner into
  # :string for the rest of the file, and every later assertion then matches
  # against text the scanner believes is a literal.
  defp scan(<<"'\\", c::utf8, "'", rest::binary>>, :code, acc, lang),
    do: scan(rest, :code, ["'", <<c::utf8>>, "\\'" | acc], lang)

  defp scan(<<"'", c::utf8, "'", rest::binary>>, :code, acc, lang),
    do: scan(rest, :code, ["'", <<c::utf8>>, "'" | acc], lang)

  defp scan(<<"//", rest::binary>>, :code, acc, lang), do: scan(rest, :line_comment, acc, lang)

  defp scan(<<"\n", rest::binary>>, :line_comment, acc, lang),
    do: scan(rest, :code, ["\n" | acc], lang)

  defp scan(<<_::utf8, rest::binary>>, :line_comment, acc, lang),
    do: scan(rest, :line_comment, acc, lang)

  # Swift block comments nest; C's, and so Objective-C's, do not. Tracking depth
  # matters for the same reason the block-comment case exists at all:
  # `/* outer /* inner */ code() */` would otherwise leave `code() */` looking
  # like live source. Applying Swift's rule to a `.m` file has the opposite
  # failure — a comment that merely mentions `/*` swallows the rest of the file
  # — which is why the language is a parameter rather than an assumption.
  defp scan(<<"/*", rest::binary>>, :code, acc, lang), do: scan(rest, {:block, 1}, acc, lang)

  defp scan(<<"/*", rest::binary>>, {:block, n}, acc, :swift),
    do: scan(rest, {:block, n + 1}, acc, :swift)

  defp scan(<<"/*", rest::binary>>, {:block, n}, acc, :objc),
    do: scan(rest, {:block, n}, acc, :objc)

  defp scan(<<"*/", rest::binary>>, {:block, 1}, acc, lang), do: scan(rest, :code, acc, lang)

  defp scan(<<"*/", rest::binary>>, {:block, n}, acc, lang),
    do: scan(rest, {:block, n - 1}, acc, lang)

  defp scan(<<"\n", rest::binary>>, {:block, n}, acc, lang),
    do: scan(rest, {:block, n}, ["\n" | acc], lang)

  defp scan(<<_::utf8, rest::binary>>, {:block, n}, acc, lang),
    do: scan(rest, {:block, n}, acc, lang)

  defp scan(<<c::utf8, rest::binary>>, :code, acc, lang),
    do: scan(rest, :code, [<<c::utf8>> | acc], lang)

  defp simplify({:block, _}), do: :block_comment
  defp simplify(state), do: state
end
