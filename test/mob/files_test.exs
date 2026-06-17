defmodule Mob.FilesTest do
  use ExUnit.Case, async: true

  alias Mob.Files

  # `pick/2` itself calls `:mob_nif.files_pick/1`, which raises
  # `nif_error(not_loaded)` on host. The host-testable surface is the pure
  # logic it delegates to: `normalize_types/1` (the wire envelope sent to the
  # native picker) and `matches?/2` / `accept/2` (result enforcement). Those
  # are what these tests pin.

  describe "normalize_types/1 — extension specs" do
    test "bare extension string" do
      assert Files.normalize_types(["livemd"]) == [%{"kind" => "extension", "value" => "livemd"}]
    end

    test "leading dot is stripped" do
      assert Files.normalize_types([".livemd"]) == [%{"kind" => "extension", "value" => "livemd"}]
    end

    test "explicit {:extension, _} tuple" do
      assert Files.normalize_types([{:extension, "csv"}]) ==
               [%{"kind" => "extension", "value" => "csv"}]
    end
  end

  describe "normalize_types/1 — mime specs" do
    test "a value containing a slash is treated as MIME" do
      assert Files.normalize_types(["application/pdf"]) ==
               [%{"kind" => "mime", "value" => "application/pdf"}]
    end

    test "wildcard MIME is preserved" do
      assert Files.normalize_types(["text/*"]) == [%{"kind" => "mime", "value" => "text/*"}]
    end

    test "explicit {:mime, _} tuple" do
      assert Files.normalize_types([{:mime, "image/png"}]) ==
               [%{"kind" => "mime", "value" => "image/png"}]
    end
  end

  describe "normalize_types/1 — semantic + uti specs" do
    test "semantic atoms" do
      assert Files.normalize_types([:images, :pdf]) ==
               [
                 %{"kind" => "semantic", "value" => "images"},
                 %{"kind" => "semantic", "value" => "pdf"}
               ]
    end

    test "uti tuple" do
      assert Files.normalize_types([{:uti, "dev.livebook.livemd"}]) ==
               [%{"kind" => "uti", "value" => "dev.livebook.livemd"}]
    end
  end

  describe "normalize_types/1 — the :any escape hatch" do
    test ":any collapses to an empty (no-filter) envelope" do
      assert Files.normalize_types(:any) == []
      assert Files.normalize_types([:any]) == []
    end

    test "legacy \"*/*\" string collapses too" do
      assert Files.normalize_types(["*/*"]) == []
    end

    test ":any anywhere in the list clears the whole filter" do
      assert Files.normalize_types(["livemd", :any]) == []
    end

    test "a bare spec is wrapped into a list" do
      assert Files.normalize_types("livemd") == [%{"kind" => "extension", "value" => "livemd"}]
    end
  end

  test "the envelope is JSON-encodable (the wire contract with native)" do
    envelope = Files.normalize_types(["livemd", "application/pdf", :images])
    decoded = :json.decode(IO.iodata_to_binary(:json.encode(envelope)))

    assert decoded == [
             %{"kind" => "extension", "value" => "livemd"},
             %{"kind" => "mime", "value" => "application/pdf"},
             %{"kind" => "semantic", "value" => "images"}
           ]
  end

  describe "matches?/2 — extension enforcement" do
    test "accepts a matching extension, case-insensitively" do
      assert Files.matches?(%{name: "demo.livemd", mime: "text/plain"}, ["livemd"])
      assert Files.matches?(%{name: "DEMO.LIVEMD", mime: "text/plain"}, ["livemd"])
    end

    test "rejects a non-matching extension" do
      refute Files.matches?(%{name: "photo.png", mime: "image/png"}, ["livemd"])
    end

    test "works on string-keyed items (decoded from native JSON)" do
      assert Files.matches?(%{"name" => "demo.livemd", "mime" => "text/plain"}, ["livemd"])
    end
  end

  describe "matches?/2 — mime + semantic enforcement" do
    test "exact MIME match" do
      assert Files.matches?(%{name: "r.pdf", mime: "application/pdf"}, [
               {:mime, "application/pdf"}
             ])

      refute Files.matches?(%{name: "r.txt", mime: "text/plain"}, [{:mime, "application/pdf"}])
    end

    test "wildcard MIME match" do
      assert Files.matches?(%{name: "a.png", mime: "image/png"}, ["image/*"])
      refute Files.matches?(%{name: "a.txt", mime: "text/plain"}, ["image/*"])
    end

    test "semantic group maps to a MIME wildcard" do
      assert Files.matches?(%{name: "a.png", mime: "image/png"}, [:images])
      refute Files.matches?(%{name: "a.pdf", mime: "application/pdf"}, [:images])
    end
  end

  describe "matches?/2 — degenerate / non-enforceable cases" do
    test ":any / empty types accepts everything" do
      assert Files.matches?(%{name: "x.bin", mime: "application/octet-stream"}, :any)
      assert Files.matches?(%{name: "x.bin", mime: "application/octet-stream"}, [])
    end

    test "a uti-only filter is treated as already-enforced by the iOS picker" do
      assert Files.matches?(
               %{name: "x.bin", mime: "application/octet-stream"},
               [{:uti, "dev.livebook.livemd"}]
             )
    end

    test "matches if ANY spec matches" do
      item = %{name: "demo.livemd", mime: "text/plain"}
      assert Files.matches?(item, ["csv", "livemd"])
    end
  end

  describe "accept/2" do
    test "keeps only matching items" do
      items = [
        %{name: "a.livemd", mime: "text/plain"},
        %{name: "b.png", mime: "image/png"},
        %{name: "c.livemd", mime: "text/plain"}
      ]

      assert Files.accept(items, ["livemd"]) == [
               %{name: "a.livemd", mime: "text/plain"},
               %{name: "c.livemd", mime: "text/plain"}
             ]
    end

    test "with :any keeps everything" do
      items = [%{name: "a.png", mime: "image/png"}]
      assert Files.accept(items, :any) == items
    end
  end
end
