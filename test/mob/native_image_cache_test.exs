# These source-contract tests guard native SwiftUI behavior that Elixir cannot execute.
# credo:disable-for-this-file Jump.CredoChecks.VacuousTest

# A tiny Swift scanner: drops `//` line comments and `/* */` block comments and
# copies string literals through verbatim, so a `"http://"` prefix check is not
# mistaken for the start of a comment.
#
# Every assertion in the test module below runs against stripped text, because a
# source-contract test is only worth having if the prose sitting next to the
# code cannot satisfy it. `assert source =~ "NSCache"` passes just as happily
# against a file whose only NSCache is the word in a comment saying someone
# ought to add one, and the region this file asserts over is heavily commented
# exactly where the assertions look.
#
# It lives in its own module so the test module can call it from a `@ios`
# attribute: a module attribute is evaluated while its own module is still being
# compiled, so it cannot call that module's own functions.
defmodule Mob.NativeImageCacheTest.SwiftSource do
  @moduledoc false

  # Lines left holding nothing but whitespace are dropped as well. Removing a
  # comment leaves the indentation that preceded it behind, and without this the
  # stripped text of a well-commented function is riddled with blank lines that
  # every multi-line assertion would then have to encode. That would make the
  # assertions a hostage to where the comments happen to sit rather than to the
  # code they are guarding.
  def code_only(source) do
    source
    |> strip(:code, [])
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp strip(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip(<<"//", rest::binary>>, :code, acc), do: strip(rest, :line, acc)
  defp strip(<<"/*", rest::binary>>, :code, acc), do: strip(rest, :block, acc)
  defp strip(<<"\"", rest::binary>>, :code, acc), do: strip(rest, :string, ["\"" | acc])
  defp strip(<<c::utf8, rest::binary>>, :code, acc), do: strip(rest, :code, [<<c::utf8>> | acc])

  defp strip(<<"\n", rest::binary>>, :line, acc), do: strip(rest, :code, ["\n" | acc])
  defp strip(<<_c::utf8, rest::binary>>, :line, acc), do: strip(rest, :line, acc)

  defp strip(<<"*/", rest::binary>>, :block, acc), do: strip(rest, :code, acc)
  defp strip(<<_c::utf8, rest::binary>>, :block, acc), do: strip(rest, :block, acc)

  # Swift escapes, including the `\(` that opens a string interpolation, are
  # copied through so the escaped quote in `"a \" b"` does not close the string
  # and desynchronise everything after it.
  defp strip(<<"\\", c::utf8, rest::binary>>, :string, acc),
    do: strip(rest, :string, [<<c::utf8>>, "\\" | acc])

  defp strip(<<"\"", rest::binary>>, :string, acc), do: strip(rest, :code, ["\"" | acc])

  defp strip(<<c::utf8, rest::binary>>, :string, acc),
    do: strip(rest, :string, [<<c::utf8>> | acc])
end

defmodule Mob.NativeImageCacheTest do
  @moduledoc """
  Local-file images are decoded once and cached, not re-decoded inside `body`.

  `UIImage(contentsOfFile:)` is a synchronous read plus a full decode with no
  system cache behind it. Sitting in a SwiftUI `body` it runs on the main thread
  on every evaluation of the node, and because MobRootView keys its subtree on
  `.id(currentNavVersion)` every navigation rebuilds the tree and re-decodes
  every local image on the incoming screen while the transition is animating.
  Source-asserted because there is no host-side way to observe how often SwiftUI
  evaluates a body, or what UIKit had to decode to get there.
  """
  use ExUnit.Case, async: true

  alias Mob.NativeImageCacheTest.SwiftSource

  @ios_source File.read!(Path.expand("../../ios/MobRootView.swift", __DIR__))
  @ios SwiftSource.code_only(@ios_source)

  defp region(source, from, to) do
    case String.split(source, from) do
      [_, rest | _] -> rest |> String.split(to) |> Enum.at(0)
      _ -> flunk("region starting at #{inspect(from)} not found")
    end
  end

  describe "the comment stripper the rest of this file leans on" do
    test "removes line and block comments but leaves string literals intact" do
      swift = """
      let a = 1 // trailing NOPE
      // whole-line NOPE
      /* block
         NOPE */
      let b = "http://example.com" // NOPE
      let c = "a \\" b // still a string"
      """

      stripped = SwiftSource.code_only(swift)

      refute stripped =~ "NOPE"
      assert stripped =~ "let a = 1"
      assert stripped =~ ~s|"http://example.com"|
      assert stripped =~ ~s|"a \\" b // still a string"|
    end

    test "does not desynchronise partway through the real source" do
      # Cheap insurance. If the scanner mistook something for an unterminated
      # string it would silently eat the rest of the file, and every `refute`
      # below would become a free pass.
      assert @ios =~ "private struct MobImage: View {"
      assert @ios =~ "final class MobImageCache {"
      assert @ios =~ "func mobIdentifiedChildren("
      assert byte_size(@ios) > div(byte_size(@ios_source), 3)
    end
  end

  describe "MobImage body" do
    setup do
      %{body: region(@ios, "private struct MobImage: View {", "\n}\n")}
    end

    test "does not read and decode from disk inside body", %{body: body} do
      # The regression this change exists to prevent: a synchronous read plus a
      # full decode on the main thread, once per body evaluation, per image, on
      # every navigation.
      refute body =~ "UIImage(contentsOfFile:",
             "MobImage decodes from disk directly again; it must go through MobImageCache"
    end

    test "the local-file branch goes through the cache", %{body: body} do
      assert body =~ "MobImageCache.shared.image(atPath: src)"
    end

    test "a missing or undecodable file still falls back to the placeholder", %{body: body} do
      # The cache returns nil on exactly the inputs the uncached call returned
      # nil for, so this `else` is still the only thing between a bad path and a
      # blank hole in the layout.
      assert body =~
               "} else if let uiImage = MobImageCache.shared.image(atPath: src) {\n" <>
                 "                    Image(uiImage: uiImage)\n" <>
                 "                        .resizable()\n" <>
                 "                        .aspectRatio(contentMode: contentMode)\n" <>
                 "                } else {\n" <>
                 "                    placeholder\n" <>
                 "                }"

      # And the outer "no src at all" fallback.
      assert body =~ "} else {\n                placeholder\n            }"
    end

    test "the http(s) branch is untouched", %{body: body} do
      # URLSession already caches those, and AsyncImage is asynchronous, so it
      # was never the main-thread problem. Nothing there should have been
      # rerouted through the local-file cache.
      assert body =~ "if src.hasPrefix(\"http://\") || src.hasPrefix(\"https://\"),"
      assert body =~ "AsyncImage(url: url) { phase in"
      refute body =~ "MobImageCache.shared.image(atPath: url"
    end
  end

  describe "MobImageCache" do
    setup do
      %{cache: region(@ios, "final class MobImageCache {", "\n}\n")}
    end

    test "is an NSCache, not a dictionary", %{cache: cache} do
      # A Dictionary grows without bound and releases nothing under memory
      # pressure; NSCache evicts on the system's own low-memory notifications,
      # on top of whatever ceiling we set.
      assert cache =~ "NSCache<NSString, UIImage>()"
      refute cache =~ "[String: UIImage]"
      refute cache =~ "Dictionary"
    end

    test "sets a cost ceiling", %{cache: cache} do
      assert cache =~ "cache.totalCostLimit = Self.budget()"

      # A flat budget is only defensible on the largest device it runs on. Mob
      # targets old hardware deliberately, so the ceiling has to scale down.
      assert cache =~ "ProcessInfo.processInfo.physicalMemory"
      assert cache =~ ~r/min\(64 \* 1024 \* 1024, max\(16 \* 1024 \* 1024/
    end

    test "the key carries an invalidation component, not just the path", %{cache: cache} do
      # Path-only keying serves a superseded image for the life of the process
      # once a file is rewritten in place: a re-cropped photo, a re-downloaded
      # avatar landing at the same cache location.
      key = region(cache, "static func cacheKey(forPath path: String) -> NSString? {", "\n    }")

      assert key =~ "FileManager.default.attributesOfItem(atPath: path)"
      assert key =~ "attrs[.size]"
      assert key =~ "attrs[.modificationDate]"

      # And all three fields actually reach the key, field-separated so a
      # numeric path suffix cannot run into the size and collide with a
      # different (path, size) pair.
      assert key =~ ~s|"\\(path)\\u{1}\\(size)\\u{1}\\(mtime)" as NSString|
    end

    test "an unusable key bypasses the cache rather than storing under a partial one",
         %{cache: cache} do
      # If the stat fails there is no way to notice a later edit of that path,
      # so the only safe move is the uncached one. This is also the missing-file
      # path, which must behave exactly as it did before.
      assert cache =~
               "guard let key = Self.cacheKey(forPath: path) else {\n" <>
                 "            return UIImage(contentsOfFile: path)\n" <>
                 "        }"
    end

    test "cost is the decoded byte size, not the file size", %{cache: cache} do
      assert cache =~ "cache.setObject(decoded, forKey: key, cost: Self.decodedByteCost(decoded))"

      cost = region(cache, "static func decodedByteCost(_ image: UIImage) -> Int {", "\n    }")

      # bytesPerRow * height is the decoded bitmap, and bytesPerRow already
      # accounts for row padding and for formats that are not 4 bytes per pixel.
      assert cost =~ "cg.bytesPerRow * cg.height"
      assert cost =~ "image.size.width * scale * image.size.height * scale * 4"

      # Nothing in the cost may come from the file on disk. A 2 MB JPEG is about
      # 14 MB decoded, so a file-size cost would let the cache hold several
      # times the memory it believes it is holding, which defeats the ceiling.
      refute cost =~ "attributesOfItem"
      refute cost =~ "attrs"
      refute cost =~ "fileSize"
    end

    test "a failed decode is not cached", %{cache: cache} do
      # A path can become valid later, a download finishing into it being the
      # obvious case, and a remembered nil would pin the placeholder there for
      # the life of the process.
      assert cache =~
               "guard let decoded = UIImage(contentsOfFile: path) else {\n" <>
                 "            return nil\n" <>
                 "        }"

      # Exactly one insertion, on the success path only.
      inserts = cache |> String.split("setObject") |> length()
      assert inserts - 1 == 1, "expected a single setObject call, found #{inserts - 1}"
    end
  end
end
