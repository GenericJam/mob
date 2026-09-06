# Source-contract test: the Android NIF table and its capability map are native
# structures Elixir cannot execute. Guards MOB-146.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest
defmodule Mob.AndroidNativeStatsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  setup_all do
    {:ok, zig: File.read!(Path.join(@root, "android/jni/mob_nif.zig"))}
  end

  test "native frame timing is registered as a NIF", %{zig: zig} do
    # Without these Mob.RenderStats.native_summary/1 returns {:error, :unsupported}
    # on Android, which is what it did before this ticket — and it looks
    # identical to "the feature is off", which is why it went unnoticed.
    assert zig =~ ~s(.name = "native_stats", .arity = 0)
    assert zig =~ ~s(.name = "native_stats_enable", .arity = 1)
  end

  test "the Kotlin methods behind them are looked up optionally", %{zig: zig} do
    # cacheOptional, not cacheRequired: an app generated before this ticket has
    # no renderStats method, and must keep loading rather than failing at boot
    # with every other NIF.
    assert zig =~ ~s|cacheOptional(jenv, "renderStats", "()Ljava/lang/String;"|
    assert zig =~ ~s|cacheOptional(jenv, "renderStatsEnable", "(Z)Z"|
  end

  test "capability keys and values stay positionally aligned", %{zig: zig} do
    # These are two parallel arrays zipped into a map by position. Getting them
    # out of step does not fail to compile — the map then reports one NIF's
    # availability under another's name.
    #
    # Counting is not enough to catch that: inserting a key mid-array while
    # appending its value at the end keeps the counts equal and produces
    # exactly the misordering. So this pairs them up and checks the pairing.
    body = capabilities_body(zig)
    keys = Regex.scan(~r/erts\.atom\(env, "(\w+)"\)/, section(body, "keys"))
    vals = Regex.scan(~r/boolAtom\(env, ([^)]*)\)/, section(body, "vals"))

    assert length(keys) == length(vals),
           "capabilities has #{length(keys)} keys and #{length(vals)} values"

    pairs =
      Enum.zip(
        Enum.map(keys, fn [_, name] -> name end),
        Enum.map(vals, fn [_, expr] -> String.trim(expr) end)
      )

    # Every key whose value names a Bridge handle must name the handle for
    # THAT key. `native_stats` is served by `render_stats`, and the two
    # deliberate `false` literals (ax_action, sample_region) are exempt because
    # no bridge method backs them at all.
    aliases = %{"native_stats" => "render_stats", "view_tree" => "ui_view_tree"}

    for {key, expr} <- pairs, String.starts_with?(expr, "Bridge.") do
      expected = Map.get(aliases, key, key)

      assert expr == "Bridge.#{expected} != null",
             "capability #{inspect(key)} reports #{expr}, which belongs to a " <>
               "different NIF — the arrays are out of step from here on"
    end

    assert {"native_stats", "Bridge.render_stats != null"} in pairs,
           "native_stats is registered but not reported by capabilities/1, so " <>
             "an agent cannot discover it without calling it and catching the error"
  end

  defp capabilities_body(zig) do
    [_, body] = String.split(zig, "export fn nif_capabilities", parts: 2)
    [body | _] = String.split(body, "\nexport fn ", parts: 2)
    body
  end

  defp section(body, name) do
    [_, rest] = String.split(body, "const #{name} = [_]erts.ERL_NIF_TERM{", parts: 2)
    [section | _] = String.split(rest, "    };", parts: 2)
    section
  end
end
