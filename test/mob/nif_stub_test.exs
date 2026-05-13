defmodule Mob.NifStubTest do
  use ExUnit.Case, async: true

  # Pins the contract between `-nifs([...])`, `-export([...])`, and the
  # function clauses in `src/mob_nif.erl`. This caught a real bug:
  # `resolve_ipv4/1` was added to `-nifs` and defined as a stub, but
  # forgotten in `-export`. The Erlang compiler accepts that quietly
  # (just emits a "function unused" warning); the failure mode surfaces
  # only on-device when `erlang:load_nif/2` rejects the NIF library
  # with `{bad_lib, "Function not found mob_nif:<name>/<arity>"}`,
  # the module is purged, and every call to mob_nif becomes `:undef`.
  #
  # The test parses the .erl source rather than reading the .beam
  # because OTP doesn't expose the `-nifs` declaration in the standard
  # attributes chunk.

  @source Path.expand("../../src/mob_nif.erl", __DIR__)

  setup_all do
    src = File.read!(@source)
    {:ok, exports: parse_block(src, "-export"), nifs: parse_block(src, "-nifs")}
  end

  test "the -nifs declaration is non-empty (sanity)", %{nifs: nifs} do
    assert length(nifs) > 0
  end

  test "every -nifs entry has a matching -export entry", %{
    exports: exports,
    nifs: nifs
  } do
    # The Erlang compiler doesn't enforce this. Forgetting an export
    # for a name in -nifs is silently accepted at build time but blows
    # up at runtime as `bad_lib: Function not found mob_nif:<name>/<n>`
    # on the device — and because that's an on_load failure, the
    # module is purged and ALL mob_nif calls become :undef. The first
    # symptom you see is `mob_nif:log/1` failing during BEAM boot.
    missing = nifs -- exports

    assert missing == [],
           "Names in -nifs but not in -export — the iOS-device NIF load will " <>
             "fail with `Function not found` and the module will be purged.\n" <>
             "Missing: #{inspect(missing)}"
  end

  test "every -nifs entry has a stub clause that raises nif_error", %{
    nifs: nifs
  } do
    # Each NIF must have a fallback definition `<name>(_, _, ...) ->
    # erlang:nif_error(not_loaded).`. Without it, callers on host /
    # in tests / before the NIF loads hit `:undef` instead of the
    # documented `:not_loaded` atom.
    src = File.read!(@source)

    missing =
      Enum.filter(nifs, fn {name, arity} ->
        # Match `<name>(args) -> erlang:nif_error(not_loaded).` — args
        # are typically `_Foo, _Bar` matching the arity.
        pattern =
          ~r/^#{Regex.escape(Atom.to_string(name))}\([^)]*\)\s*->\s*erlang:nif_error\(not_loaded\)\.$/m

        not (Regex.match?(pattern, src) and
               arity_matches?(src, name, arity))
      end)

    assert missing == [],
           "Names in -nifs without a stub clause raising nif_error(not_loaded):\n" <>
             inspect(missing)
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Parse the contents of `-<keyword>([ name/arity, ... ]).` into a
  # list of `{:name, arity}` tuples. Lines may be wrapped, the inner
  # list may have comments (skipped) and a trailing comma is allowed.
  defp parse_block(src, keyword) do
    case Regex.run(~r/#{Regex.escape(keyword)}\(\[(.*?)\]\)\./s, src) do
      [_, inner] ->
        inner
        |> String.split("\n")
        |> Enum.map(&strip_comment/1)
        |> Enum.join(" ")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_name_arity/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp strip_comment(line) do
    case String.split(line, "%", parts: 2) do
      [code, _comment] -> code
      [code] -> code
    end
  end

  defp parse_name_arity(entry) do
    case Regex.run(~r/^([a-z][a-z0-9_]*)\/(\d+)$/, entry) do
      [_, name, arity] -> {String.to_atom(name), String.to_integer(arity)}
      _ -> nil
    end
  end

  # The regex in the stub-clause test only checks that *some* clause
  # for `name` exists. This narrows to "name with an arity-matching
  # arg list."
  defp arity_matches?(src, name, arity) do
    name_str = Atom.to_string(name)
    # Count commas + 1 = arity (or 0 args = no commas, name() form).
    pattern =
      if arity == 0 do
        ~r/^#{Regex.escape(name_str)}\(\)\s*->\s*erlang:nif_error\(not_loaded\)\.$/m
      else
        # Match `name(_A1, _A2, ...)` with exactly `arity` underscore-prefixed args.
        args = Enum.map(1..arity, fn _ -> "_[A-Za-z0-9_]*" end) |> Enum.join(",\\s*")
        ~r/^#{Regex.escape(name_str)}\(#{args}\)\s*->\s*erlang:nif_error\(not_loaded\)\.$/m
      end

    Regex.match?(pattern, src)
  end
end
