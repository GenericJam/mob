defmodule Mob.DifferentialTest do
  use ExUnit.Case, async: true

  alias Mob.Differential

  # The comparator's whole reason for existing is to catch a divergence class
  # (MOB-147's B-1 kind) the day it lands. Each rule below is paired with a
  # mutation of the comparator that must fail the test — the CLAUDE.md bar,
  # applied here on purpose: the reviewer keeps finding my tests would still
  # pass with the fix reverted.

  defp mk(type, opts \\ []) do
    %{
      type: type,
      class: Keyword.get(opts, :class),
      label: Keyword.get(opts, :label),
      value: Keyword.get(opts, :value),
      frame: Keyword.get(opts, :frame),
      bg_color: Keyword.get(opts, :bg_color),
      text_color: Keyword.get(opts, :text_color),
      children: Keyword.get(opts, :children, [])
    }
  end

  defp root(kids), do: mk(:root, frame: {0.0, 0.0, 393.0, 852.0}, children: kids)

  describe "identical trees" do
    test "an empty tree pair compares :ok" do
      assert Differential.compare(root([]), root([])) == :ok
    end

    test "a plausible fixture compares :ok on both sides" do
      tree =
        root([
          mk(:scroll,
            children: [
              mk(:column,
                children: [
                  mk(:text, label: "Title"),
                  mk(:button, label: "Roll Dice", frame: {24.0, 400.0, 327.0, 53.5})
                ]
              )
            ]
          )
        ])

      assert Differential.compare(tree, tree) == :ok
    end
  end

  describe "structure" do
    test "a different type at a matched position is a divergence" do
      # The MOB-147 B-1 shape: one platform emits `text`, the other `button`
      # for the same intended node. Reason names the difference cleanly so a
      # defect reader is not left guessing which side is which.
      ios = root([mk(:button, label: "Go")])
      android = root([mk(:text, label: "Go")])

      assert {:divergence, d} = Differential.compare(ios, android)
      assert d.reason == :type
      assert d.ios == :button
      assert d.android == :text
      assert d.path == [0]
    end

    test "different number of children at any level is a divergence" do
      ios = root([mk(:column, children: [mk(:text), mk(:text)])])
      android = root([mk(:column, children: [mk(:text)])])

      assert {:divergence, d} = Differential.compare(ios, android)
      assert d.reason == :child_count
      assert d.ios == 2
      assert d.android == 1
    end

    test "the first divergence in child order wins over deeper ones" do
      # Two problems in the same tree. The leftmost child differs on type; a
      # deeper problem sits in the second child. A comparator that reported
      # the deeper one would send a reader past the actual first defect.
      ios =
        root([
          mk(:button, label: "Left"),
          mk(:column, children: [mk(:text, label: "A")])
        ])

      android =
        root([
          mk(:text, label: "Left"),
          mk(:column, children: [mk(:text, label: "B")])
        ])

      assert {:divergence, d} = Differential.compare(ios, android)
      assert d.reason == :type
      assert d.path == [0]
    end
  end

  describe "label and value" do
    test "different labels are a divergence" do
      ios = root([mk(:button, label: "Submit")])
      android = root([mk(:button, label: "Send")])

      assert {:divergence, %{reason: :label, ios: "Submit", android: "Send", path: [0]}} =
               Differential.compare(ios, android)
    end

    test "different values are a divergence" do
      ios = root([mk(:text_field, value: "kevin@")])
      android = root([mk(:text_field, value: "kevin@example")])

      assert {:divergence, %{reason: :value}} = Differential.compare(ios, android)
    end
  end

  describe "frame comparison" do
    test "identical frames compare :ok" do
      ios = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      android = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      assert Differential.compare(ios, android) == :ok
    end

    test "frames within the default 1.0 dp tolerance compare :ok" do
      # Layout engines round differently. Small deltas are ordinary.
      ios = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      android = root([mk(:button, frame: {24.5, 400.7, 300.2, 50.1})])
      assert Differential.compare(ios, android) == :ok
    end

    test "a frame delta beyond tolerance is a divergence" do
      ios = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      android = root([mk(:button, frame: {24.0, 400.0, 300.0, 100.0})])

      assert {:divergence, %{reason: :frame}} = Differential.compare(ios, android)
    end

    test "an Android-side missing frame is not a divergence" do
      # The unblocker reports frame only for id'd nodes. Reporting nil as a
      # divergence would flag every non-id'd node in every fixture; the fixture
      # author chooses geometry coverage by giving ids to the nodes that need
      # it.
      ios = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      android = root([mk(:button, frame: nil)])
      assert Differential.compare(ios, android) == :ok
    end

    test "an iOS-side missing frame is not a divergence either" do
      ios = root([mk(:button, frame: nil)])
      android = root([mk(:button, frame: {24.0, 400.0, 300.0, 50.0})])
      assert Differential.compare(ios, android) == :ok
    end

    test "the root frame is never compared" do
      # It is the screen size, which legitimately differs across an iPad and a
      # phone. If this ever reported, every cross-device run would be a
      # divergence.
      ios = %{root([]) | frame: {0.0, 0.0, 393.0, 852.0}}
      android = %{root([]) | frame: {0.0, 0.0, 411.4, 914.3}}
      assert Differential.compare(ios, android) == :ok
    end

    test "the tolerance boundary is inclusive: delta exactly at tolerance is :ok" do
      # A team relying on "small differences are ordinary rounding" needs a test
      # of exactly what "at tolerance" means. Nothing pinned it before, so
      # `<=` and `<` were indistinguishable in the suite.
      ios =
        mk(:root,
          frame: {0.0, 0.0, 393.0, 852.0},
          children: [mk(:button, frame: {0.0, 0.0, 100.0, 100.0})]
        )

      android_at =
        mk(:root,
          frame: {0.0, 0.0, 393.0, 852.0},
          children: [mk(:button, frame: {0.0, 0.0, 101.0, 100.0})]
        )

      android_over =
        mk(:root,
          frame: {0.0, 0.0, 393.0, 852.0},
          children: [mk(:button, frame: {0.0, 0.0, 101.001, 100.0})]
        )

      assert Differential.compare(ios, android_at) == :ok,
             "delta == tolerance must be :ok (inclusive boundary)"

      assert {:divergence, %{reason: :frame}} = Differential.compare(ios, android_over),
             "delta > tolerance must diverge"
    end

    test "the tolerance is configurable" do
      # A team on a device where the layout engines round unusually can raise
      # it; a fixture that needs pixel-accurate agreement can lower it.
      ios = root([mk(:button, frame: {0.0, 0.0, 100.0, 100.0})])
      android = root([mk(:button, frame: {0.0, 0.0, 100.0, 103.0})])

      assert {:divergence, _} = Differential.compare(ios, android)
      assert Differential.compare(ios, android, frame_tolerance_dp: 5.0) == :ok
    end
  end

  describe "when a device is not ready" do
    test "a malformed tree returns {:error, :not_ready} rather than crashing" do
      # A fixture author hand-building a partial tree, or a normalize step that
      # drifted, would previously crash the caller with FunctionClauseError
      # deep in the walk. Harness failure is not a defect: the promise made by
      # `Mob.Test.view_tree/1`'s error shape has to hold in every place the
      # caller can see.
      good = mk(:root, children: [mk(:button, label: "ok")])
      no_children_key = %{type: :root}
      children_has_nil = %{good | children: [nil]}
      children_has_string = %{good | children: ["not a node"]}

      assert Differential.compare(good, no_children_key) == {:error, :not_ready}
      assert Differential.compare(good, children_has_nil) == {:error, :not_ready}
      assert Differential.compare(good, children_has_string) == {:error, :not_ready}
    end

    test "either side missing returns {:error, :not_ready}, not a divergence" do
      # `Mob.Test.view_tree/1` can return `{:error, :not_loaded}`, `:no_window`,
      # or nil when a device is starting up. Reporting that as a divergence
      # would file the harness's own gap as a defect against the framework.
      tree = root([mk(:text, label: "hi")])

      assert Differential.compare(tree, {:error, :not_loaded}) == {:error, :not_ready}
      assert Differential.compare({:error, :not_loaded}, tree) == {:error, :not_ready}
      assert Differential.compare(tree, :no_window) == {:error, :not_ready}
      assert Differential.compare(nil, tree) == {:error, :not_ready}
    end
  end

  describe "schema drift" do
    test "which of the eight keys the comparator actually compares" do
      # Not just a literal check — this drives `compare/3` with a tree that
      # differs only on each field in turn and asserts which ones surface. If
      # someone starts comparing `class` (or stops comparing `label`), this
      # test names it in the failure message. The canonical-keys assertion at
      # the bottom is the drift guard: a new field lands with an intentional
      # choice or the test breaks.
      base =
        mk(:root,
          frame: {0.0, 0.0, 393.0, 852.0},
          children: [
            mk(:button, label: "same", value: nil, frame: {0.0, 0.0, 100.0, 100.0})
          ]
        )

      compared =
        for {field, other} <- [
              type: {:type, %{base | children: [%{hd(base.children) | type: :text}]}},
              label: {:label, %{base | children: [%{hd(base.children) | label: "other"}]}},
              value: {:value, %{base | children: [%{hd(base.children) | value: "v"}]}},
              frame:
                {:frame,
                 %{base | children: [%{hd(base.children) | frame: {0.0, 0.0, 500.0, 100.0}}]}},
              child_count: {:child_count, %{base | children: []}}
            ],
            {reason, mutated} = other,
            match?({:divergence, %{reason: ^reason}}, Differential.compare(base, mutated)),
            do: field

      assert Enum.sort(compared) == [:child_count, :frame, :label, :type, :value]

      # Skipped by design today: changing these must NOT report divergence.
      for field <- [:class, :bg_color, :text_color] do
        mutated = %{base | children: [Map.put(hd(base.children), field, :something_different)]}

        assert Differential.compare(base, mutated) == :ok,
               "#{field} is on the skipped-by-design list but comparing it now reports " <>
                 "divergence — decide to compare it or update the skipped list"
      end

      # The canonical key set: a new field on the sample tree without a
      # matching decision here breaks this assertion.
      canonical_keys = ~w(bg_color children class frame label text_color type value)a
      assert Enum.sort(Map.keys(hd(base.children))) == canonical_keys

      # Cross-check against the real normalisation contract. A field added to
      # `Mob.Test.normalize_view_tree/1` without updating this test would
      # otherwise slip through the test-local `mk/2` shape.
      normalised = Mob.Test.normalize_view_tree(%{"type" => "x"})
      assert Enum.sort(Map.keys(normalised)) == canonical_keys
    end
  end

  describe "path formatting" do
    test "root divergence" do
      ios = %{root([]) | type: :not_root}
      android = root([])
      assert {:divergence, d} = Differential.compare(ios, android)
      assert d.path == []
      assert Differential.describe(d) =~ "at root"
    end

    test "nested divergence path is walked in child order" do
      ios =
        root([
          mk(:column,
            children: [
              mk(:text),
              mk(:text),
              mk(:button, label: "One")
            ]
          )
        ])

      android =
        root([
          mk(:column,
            children: [
              mk(:text),
              mk(:text),
              mk(:button, label: "Two")
            ]
          )
        ])

      assert {:divergence, d} = Differential.compare(ios, android)
      assert d.path == [0, 2]
      assert Differential.describe(d) =~ "root -> 0.2"
      assert Differential.describe(d) =~ "label"
    end
  end
end
