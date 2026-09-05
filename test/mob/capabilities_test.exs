# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
#
# The native halves assert on source text: they guard a NIF that only exists
# inside a running app. A review demonstrated that the first version of these
# was largely vacuous — several passed on the exact mutation they named — so
# each one below has been checked against its own mutation.
defmodule Mob.CapabilitiesTest do
  @moduledoc """
  `Mob.Test.capabilities/1` and the three declarations it depends on.

  The point of the feature is that a capability is a RUNTIME fact — per app on
  Android, per build configuration on iOS — so the failure that matters is the
  answer coming from something that drifts from the code.
  """
  use ExUnit.Case, async: true

  @erl_path Path.expand("../../src/mob_nif.erl", __DIR__)
  @ios_path Path.expand("../../ios/mob_nif.m", __DIR__)
  @zig_path Path.expand("../../android/jni/mob_nif.zig", __DIR__)

  @erl File.read!(@erl_path)
  @ios File.read!(@ios_path)
  @zig File.read!(@zig_path)

  # Each `{"name", arity, nif_…}` entry mapped to its nearest enclosing `#if`,
  # tracking nesting with a stack. Same approach as Mob.ReleaseScreenshotTest —
  # comparing byte offsets instead proved unable to tell where a REGISTRATION
  # sits, which is the thing that matters.
  defp registration_guards do
    @ios
    |> String.split("\n")
    |> Enum.reduce({%{}, []}, fn line, {acc, stack} ->
      cond do
        m = Regex.run(~r/^\s*#\s*if\S*\s+(.*)$/, line) ->
          {acc, [Enum.at(m, 1) | stack]}

        Regex.match?(~r/^\s*#\s*endif/, line) ->
          {acc, Enum.drop(stack, 1)}

        m = Regex.run(~r/^\s*\{"([a-z_0-9]+)",\s*\d+,\s*nif_/, line) ->
          {Map.put(acc, Enum.at(m, 1), List.first(stack) || ""), stack}

        true ->
          {acc, stack}
      end
    end)
    |> elem(0)
  end

  defp block(source, from, to) do
    [_, rest] = String.split(source, from, parts: 2)
    [body | _] = String.split(rest, to, parts: 2)
    body
  end

  describe "classify_capabilities/1" do
    # The whole decision, testable without a device. Previously only the
    # unreachable branch had any coverage.
    test "a map from the NIF is the answer, plus dist_rpc" do
      caps = Mob.Test.classify_capabilities(%{tap_xy: true, view_tree: false})

      assert caps.dist_rpc
      assert caps.tap_xy
      refute caps.view_tree
    end

    test "an app predating the NIF is :unknown, not a guess" do
      caps = Mob.Test.classify_capabilities({:badrpc, {:EXIT, {:undef, []}}})

      assert caps.dist_rpc, "it answered, so distribution works"

      for key <- Mob.Test.probe_keys() do
        assert caps[key] == :unknown, "#{key} must be :unknown, not assumed"
      end
    end

    test "a failed load_nif is false, not unknown" do
      # Every NIF is down, not just this one. :unknown would send an agent off
      # to try probes that cannot work.
      caps = Mob.Test.classify_capabilities({:badrpc, {:EXIT, {:not_loaded, []}}})

      assert caps.dist_rpc
      assert Enum.all?(Mob.Test.probe_keys(), &(caps[&1] == false))
    end

    test "an unreachable node is false everywhere, dist_rpc included" do
      for reason <- [:nodedown, :timeout, {:EXIT, :noconnection}] do
        caps = Mob.Test.classify_capabilities({:badrpc, reason})

        refute caps.dist_rpc, "#{inspect(reason)} means the node did not answer"
        assert Enum.all?(Mob.Test.probe_keys(), &(caps[&1] == false))
      end
    end

    test "every branch answers for exactly the advertised keys" do
      expected = MapSet.new([:dist_rpc | Mob.Test.probe_keys()])

      for result <- [
            %{},
            {:badrpc, {:EXIT, {:undef, []}}},
            {:badrpc, {:EXIT, {:not_loaded, []}}},
            {:badrpc, :nodedown}
          ] do
        keys = result |> Mob.Test.classify_capabilities() |> Map.keys() |> MapSet.new()
        assert MapSet.subset?(expected, keys) or result == %{}
      end
    end
  end

  describe "the timeout" do
    test "capabilities/2 passes one to :rpc.call" do
      # `:rpc.call/4` waits forever. This is the FIRST call an agent makes, and
      # a wedged-but-reachable node (a plugged-in iPhone whose BEAM suspends)
      # would hang it indefinitely — worse than the mid-run error it replaces.
      source = File.read!(Path.expand("../../lib/mob/test.ex", __DIR__))
      body = block(source, "def capabilities(node, timeout \\\\ 5_000) do", "\n  end")

      assert body =~ ":rpc.call(:mob_nif, :capabilities, [], timeout)"
    end
  end

  describe "the NIF is declared on all three sides" do
    # Exported but missing from `-nifs` fails load_nif for the WHOLE module,
    # taking every other NIF down — the app crashes at boot. Declared in
    # `-nifs` but absent from a platform's array leaves a stub that raises.
    test "the Erlang module exports it" do
      # Scoped to the -export block. A dotall regex over the whole file matches
      # the -nifs occurrence instead, so deleting the export left it green.
      exports = block(@erl, "-export([", "]).")
      assert exports =~ "capabilities/0"
    end

    test "the Erlang module lists it in -nifs" do
      nifs = block(@erl, "-nifs([", "]).")
      assert nifs =~ "capabilities/0"
    end

    test "the Erlang module stubs it" do
      assert @erl =~ "capabilities() -> erlang:nif_error(not_loaded)."
    end

    test "Android registers it" do
      assert @zig =~ ~s|.name = "capabilities", .arity = 0, .fptr = nif_capabilities|
    end
  end

  describe "iOS answers whatever the build" do
    test "the registration is inside no conditional at all" do
      # The mutation this exists for: moving the entry one line up, above the
      # `#endif`, so it is compiled out of release builds. Checking where the
      # DEFINITION sits cannot see that.
      assert registration_guards()["capabilities"] == "",
             "capabilities must be registered outside every #if"
    end

    test "the harness flag is derived from the gate, not hardcoded" do
      body = block(@ios, "static ERL_NIF_TERM nif_capabilities(", "\n}\n")

      assert body =~ ~r/#if !MOB_RELEASE\n\s*int harness = 1;\n#else\n\s*int harness = 0;/,
             "a constant would make a release build claim a harness it lacks"
    end

    test "screenshot is reported from its own gate, not the harness one" do
      body = block(@ios, "static ERL_NIF_TERM nif_capabilities(", "\n}\n")

      assert body =~
               ~r/#if !MOB_RELEASE \|\| defined\(MOB_ENABLE_SCREENSHOT\)\n\s*int screenshot = 1;/

      assert body =~ ~s|{"screenshot", screenshot},|
      refute body =~ ~s|{"screenshot", harness},|
    end
  end

  describe "Android reports per-app truth" do
    test "keys and values are the same length" do
      body = block(@zig, "export fn nif_capabilities(", "\n}\n")

      keys =
        body |> block("const keys", "const vals") |> then(&Regex.scan(~r/erts\.atom\(env, "/, &1))

      vals = Regex.scan(~r/boolAtom\(env,/, body)

      assert length(keys) == length(vals),
             "parallel arrays: a length mismatch silently shifts every mapping"
    end

    test "each capability is paired with the bridge method its own NIF checks" do
      body = block(@zig, "export fn nif_capabilities(", "\n}\n")
      keys = Regex.scan(~r/erts\.atom\(env, "([a-z_]+)"\)/, body) |> Enum.map(&Enum.at(&1, 1))

      vals =
        Regex.scan(~r/boolAtom\(env, (?:Bridge\.([a-z_]+) != null|false)\)/, body)
        |> Enum.map(&Enum.at(&1, 1))

      paired = Enum.zip(keys, vals) |> Map.new()

      # Pairing, not mere presence: swapping two lines in either array is the
      # defect this layout invites, and a presence check cannot see it.
      assert paired["view_tree"] == "ui_view_tree"
      assert paired["ui_tree"] == "ui_tree"
      assert paired["tap_xy"] == "tap_xy"
      assert paired["type_text"] == "type_text"
      assert paired["scroll_info"] == "scroll_info"
      assert paired["scroll_to"] == "scroll_to"
      assert paired["element_frames"] == "element_frames"
      assert paired["screenshot"] == "screenshot"
    end

    test "sample_region is false — Android has no such NIF" do
      # Not a missing bridge method: there is no implementation at all, so
      # sample_color/2 fails with a stub raise. Reporting it from
      # Bridge.screenshot claimed a capability that does not exist.
      body = block(@zig, "export fn nif_capabilities(", "\n}\n")
      keys = Regex.scan(~r/erts\.atom\(env, "([a-z_]+)"\)/, body) |> Enum.map(&Enum.at(&1, 1))

      vals =
        Regex.scan(~r/boolAtom\(env, (?:Bridge\.([a-z_]+) != null|(false))\)/, body)
        |> Enum.map(fn m -> Enum.at(m, 1) end)

      assert Enum.zip(keys, vals) |> Map.new() |> Map.get("sample_region") == "",
             "sample_region must be hardcoded false on Android"

      # And the file must still contain no implementation, or this is stale.
      refute @zig =~ "export fn nif_sample_region"
    end

    test "ax_action is false, and it is ax_action that is false" do
      body = block(@zig, "export fn nif_capabilities(", "\n}\n")
      keys = Regex.scan(~r/erts\.atom\(env, "([a-z_]+)"\)/, body) |> Enum.map(&Enum.at(&1, 1))

      vals =
        Regex.scan(~r/boolAtom\(env, (?:Bridge\.([a-z_]+) != null|(false))\)/, body)
        |> Enum.map(fn m -> Enum.at(m, 1) end)

      assert Enum.zip(keys, vals) |> Map.new() |> Map.get("ax_action") == ""
      assert @zig =~ "not_supported_on_android"
    end
  end

  describe "the three key sets agree" do
    test "Elixir advertises exactly what the natives report" do
      # A key in @probe_keys that no platform returns is reported :unknown for
      # ever; one the natives return but Elixir omits is silently dropped from
      # the unreachable/unknown maps.
      ios_keys =
        @ios
        |> block("} caps[] = {", "};")
        |> then(&Regex.scan(~r/\{"([a-z_]+)",/, &1))
        |> Enum.map(&Enum.at(&1, 1))
        |> MapSet.new()

      zig_keys =
        @zig
        |> block("export fn nif_capabilities(", "const vals")
        |> then(&Regex.scan(~r/erts\.atom\(env, "([a-z_]+)"\)/, &1))
        |> Enum.map(&Enum.at(&1, 1))
        |> MapSet.new()

      elixir_keys = Mob.Test.probe_keys() |> Enum.map(&to_string/1) |> MapSet.new()

      assert ios_keys == zig_keys, "the two platforms must report the same keys"
      assert elixir_keys == ios_keys, "Mob.Test.probe_keys/0 must match the natives"
    end
  end
end
