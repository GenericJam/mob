defmodule Mob.Test.NativeSourceTest do
  @moduledoc """
  The comment stripper the native assertions run on.

  Every "native side does X" test in this suite is only as good as this
  module. A stripper that leaves a comment behind lets an assertion pass on
  prose describing code that was deleted, and one that eats real code makes a
  correct implementation look missing. Both failures are silent.
  """
  use ExUnit.Case, async: true

  import Mob.Test.NativeSource

  describe "comments are removed" do
    test "a line comment goes, and the newline stays so line numbers hold" do
      assert code_only("let a = 1 // set a\nlet b = 2\n") == "let a = 1 \nlet b = 2\n"
    end

    test "a block comment goes" do
      assert code_only("let a = /* noise */ 1") == "let a =  1"
    end

    test "commented-out code cannot satisfy an assertion" do
      refute code_only("// setRoot(node, replacesStack: true)\n") =~ "setRoot"
    end
  end

  describe "block comments nest" do
    # Swift allows `/* /* */ */`. A depth-blind scanner ends the comment at the
    # first `*/` and hands back the tail as live source, so a call that only
    # appears inside a commented-out block reads as present.
    test "an inner close does not end the outer comment" do
      source = "a()\n/* outer /* inner */ commentedOut() */\nb()\n"

      stripped = code_only(source)

      assert stripped =~ "a()"
      assert stripped =~ "b()"
      refute stripped =~ "commentedOut"
    end

    test "three deep" do
      refute code_only("/* /* /* x() */ */ */") =~ "x()"
    end

    # ...but only in Swift. C block comments do not nest, and `ios/*.m` is C.
    # Applying Swift's rule there has the opposite failure: a comment that
    # merely *mentions* `/*` — a glob like `ios/*.m`, a quoted C snippet — opens
    # a level that never closes and swallows the rest of the file, so every
    # later assertion fails with a message pointing at the assertion.
    test "not in Objective-C: a comment mentioning a glob does not eat the file" do
      source = "/* matches ios/*.m */\nsetRoot(c)\n"

      assert code_only(source, :objc) =~ "setRoot(c)"
      refute code_only(source, :objc) =~ "matches"
    end

    test "the same input is an unterminated comment in Swift, and says so" do
      assert_raise RuntimeError, ~r/ended in :block_comment/, fn ->
        code_only("/* matches ios/*.m */\nsetRoot(c)\n", :swift)
      end
    end
  end

  describe "a stuck scan is loud, not silent" do
    # Every way this scanner goes wrong leaves it in a non-code state, and from
    # there it either reports comments as code (false pass) or eats code as
    # comment (false failure). Raising is what keeps those visible.
    test "an unterminated string literal raises" do
      assert_raise RuntimeError, ~r/ended in :string/, fn ->
        code_only("let s = \"oops\nsetRoot(h)\n")
      end
    end

    test "an unterminated block comment raises" do
      assert_raise RuntimeError, ~r/ended in :block_comment/, fn ->
        code_only("a()\n/* forgot to close\n")
      end
    end
  end

  describe "Swift raw strings" do
    # `#"..."#` does not honour `\"` as an escape, so the ordinary escape rule
    # runs straight past the terminator and leaves the scanner inside a string
    # for the rest of the file — where every following comment reads as code.
    test "a trailing backslash does not swallow the terminator" do
      stripped = code_only(~S|let p = #"C:\path\"#| <> "\nsetRoot(a) // gone\n")

      assert stripped =~ "setRoot(a)"
      refute stripped =~ "gone"
    end
  end

  describe "quotes that are not string delimiters" do
    # `mob_nif.m` contains `'"'`. Treating that quote as a string delimiter
    # flips the scanner for the whole rest of the file, and every later
    # assertion then matches against text it believes is a literal.
    test "an Objective-C char literal holding a quote does not open a string" do
      source = ~S|char q = '"'; // gone
setRoot(node);
|

      stripped = code_only(source)

      assert stripped =~ "setRoot(node);"
      refute stripped =~ "gone"
    end

    test "an escaped char literal is handled too" do
      assert code_only(~S|char n = '\n'; f();|) =~ "f();"
    end

    test "a comment marker inside a string literal is not a comment" do
      assert code_only(~S|let s = "http://example.com"| <> "\n") =~ "http://example.com"
    end

    test "a comment marker inside a multi-line literal is not a comment" do
      source = ~s|let shader = """\n// not a comment\n"""\nreal()\n|

      stripped = code_only(source)

      assert stripped =~ "// not a comment"
      assert stripped =~ "real()"
    end
  end

  describe "region/3" do
    test "returns the text between the markers" do
      assert region("a FROM body TO c", "FROM", "TO") == " body "
    end

    # A missing marker used to raise MatchError from String.split's result, or
    # worse, return an empty region that every later `=~` silently failed
    # against with a message pointing at the assertion rather than the marker.
    test "says which marker was missing rather than returning nothing" do
      assert_raise RuntimeError, ~r/region start not found/, fn ->
        region("abc", "NOPE", "TO")
      end

      assert_raise RuntimeError, ~r/region end not found/, fn ->
        region("a FROM b", "FROM", "NOPE")
      end
    end
  end
end
