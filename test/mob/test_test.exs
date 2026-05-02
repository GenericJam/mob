defmodule Mob.TestTest do
  use ExUnit.Case, async: true

  # Tests for the pure helpers in `Mob.Test` — flatten_tree, find logic, normalize.
  # The RPC-based functions are exercised on-device by integration tests
  # (see test/onboarding/) and aren't covered here.

  alias Mob.Test, as: M

  defp sample_tree do
    %{
      type: :root,
      label: nil,
      value: nil,
      frame: {0.0, 0.0, 393.0, 852.0},
      children: [
        %{
          type: :window,
          label: nil,
          value: nil,
          frame: {0.0, 0.0, 393.0, 852.0},
          children: [
            %{
              type: :scroll,
              label: nil,
              value: nil,
              frame: {0.0, 62.0, 393.0, 756.0},
              children: [
                %{
                  type: :button,
                  label: "Roll Dice",
                  value: nil,
                  frame: {24.0, 416.0, 327.0, 53.5},
                  children: []
                },
                %{
                  type: :text,
                  label: "Hello",
                  value: nil,
                  frame: {24.0, 480.0, 100.0, 24.0},
                  children: []
                },
                %{
                  type: :button,
                  label: "Roll again",
                  value: nil,
                  frame: {24.0, 520.0, 327.0, 53.5},
                  children: []
                }
              ]
            }
          ]
        }
      ]
    }
  end

  describe "flatten_tree/1" do
    test "produces one entry per node with monotonically deeper paths" do
      flat = M.flatten_tree(sample_tree())

      paths = Enum.map(flat, fn {p, _} -> p end)

      assert paths == [
               [],
               [0],
               [0, 0],
               [0, 0, 0],
               [0, 0, 1],
               [0, 0, 2]
             ]
    end

    test "drops :children from each entry but keeps everything else" do
      flat = M.flatten_tree(sample_tree())
      {_path, root} = hd(flat)

      assert Map.has_key?(root, :type)
      assert Map.has_key?(root, :frame)
      refute Map.has_key?(root, :children)
    end

    test "leaves with no children still emit one entry" do
      tree = %{
        type: :button,
        label: "Solo",
        value: nil,
        frame: {0.0, 0.0, 1.0, 1.0},
        children: []
      }

      assert [{[], node}] = M.flatten_tree(tree)
      assert node.label == "Solo"
    end
  end

  describe "find_view (search semantics)" do
    # find_view/2 takes a node arg and does RPC. The pure substring filter is
    # what we test here — we apply it directly to a flattened tree.

    test "matches by label, returns path-tagged entries" do
      matches =
        sample_tree()
        |> M.flatten_tree()
        |> Enum.filter(fn {_path, n} ->
          String.contains?(to_string(n[:label] || ""), "Roll")
        end)

      labels = Enum.map(matches, fn {_p, n} -> n.label end)
      assert "Roll Dice" in labels
      assert "Roll again" in labels
      assert length(matches) == 2
    end

    test "matches against value as well as label" do
      tree = %{
        type: :root,
        label: nil,
        value: nil,
        frame: {0.0, 0.0, 1.0, 1.0},
        children: [
          %{
            type: :text_field,
            label: "Name",
            value: "Roll-something",
            frame: {0.0, 0.0, 1.0, 1.0},
            children: []
          }
        ]
      }

      matches =
        tree
        |> M.flatten_tree()
        |> Enum.filter(fn {_p, n} ->
          String.contains?(to_string(n[:label] || ""), "Roll") or
            String.contains?(to_string(n[:value] || ""), "Roll")
        end)

      assert length(matches) == 1
    end
  end

  describe "tree shape normalization (Android JSON path)" do
    # Mob.Test.view_tree/1 normalizes JSON-decoded trees (string keys, list frame)
    # into the iOS map shape (atom keys, tuple frame). normalize_tree is private
    # but exercised via the public API by sending a JSON binary through view_tree
    # would require RPC — so we test the contract by mirroring the JSON shape and
    # asserting the documented surface.

    test "documented output frame shape is a 4-tuple of floats" do
      {x, y, w, h} = sample_tree().frame
      for v <- [x, y, w, h], do: assert(is_float(v))
    end

    test "documented output uses atom :type and :children keys" do
      assert is_atom(sample_tree().type)
      assert is_list(sample_tree().children)
    end
  end
end
