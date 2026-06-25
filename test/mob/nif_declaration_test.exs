defmodule Mob.NifDeclarationTest do
  # `load_nif/2` fails — and purges mob_nif, crashing every app at boot — if the
  # native NIF tables register a function that the module's `-nifs([])` attribute
  # doesn't declare. This can't be caught by a host test (NIFs never load on the
  # host), so guard it at the source: every {name, arity} in the iOS and Android
  # native tables MUST appear in `-nifs([])` in src/mob_nif.erl. Regression for
  # 0.7.6, where device_orientation/0 + device_lock_orientation/1 were added to
  # the native tables and -export but not -nifs, so on_load failed everywhere.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @erl Path.join(@root, "src/mob_nif.erl")
  @zig Path.join(@root, "android/jni/mob_nif.zig")
  @objc Path.join(@root, "ios/mob_nif.m")

  defp declared_nifs do
    src = File.read!(@erl)
    # The block between `-nifs([` and the closing `]).`
    [_, block] = String.split(src, "-nifs([", parts: 2)
    [block, _] = String.split(block, "]).", parts: 2)

    Regex.scan(~r/^\s*([a-z_0-9]+)\/(\d+)/m, block)
    |> Enum.map(fn [_, name, arity] -> {name, String.to_integer(arity)} end)
    |> MapSet.new()
  end

  defp native_nifs(:android) do
    Regex.scan(~r/\.name = "([a-z_0-9]+)", \.arity = (\d+)/, File.read!(@zig))
    |> Enum.map(fn [_, name, arity] -> {name, String.to_integer(arity)} end)
    |> MapSet.new()
  end

  defp native_nifs(:ios) do
    Regex.scan(~r/\{"([a-z_0-9]+)",\s*(\d+),\s*nif_/, File.read!(@objc))
    |> Enum.map(fn [_, name, arity] -> {name, String.to_integer(arity)} end)
    |> MapSet.new()
  end

  test "-nifs([]) is non-empty (parser sanity)" do
    assert MapSet.size(declared_nifs()) > 50
  end

  for platform <- [:android, :ios] do
    test "every #{platform} native NIF is declared in -nifs([])" do
      declared = declared_nifs()
      native = native_nifs(unquote(platform))

      assert MapSet.size(native) > 50, "parsed too few #{unquote(platform)} NIFs — parser broke"

      undeclared = MapSet.difference(native, declared)

      assert MapSet.equal?(undeclared, MapSet.new()),
             "#{unquote(platform)} registers NIFs missing from -nifs([]) in src/mob_nif.erl " <>
               "(load_nif will fail → mob_nif purged → boot crash): " <>
               Enum.map_join(undeclared, ", ", fn {n, a} -> "#{n}/#{a}" end)
    end
  end
end
