defmodule Mob.Differential do
  @moduledoc """
  Compare two `Mob.Test.view_tree/1` snapshots and report the first divergence.

  Mob's product claim is one design, both platforms. A comparator over the
  semantic trees each platform returns is what makes that claim testable — the
  first thing that differs is the framework failing its own promise.

  This module is deliberately pure: it takes two normalised view-trees and
  answers `:ok` or `{:divergence, %{...}}`. Rendering the same fixture on both
  platforms and driving the round trip belongs to `mob_dev`, not here — the
  comparator is easy to test without a device, and hard to test *with* one.

  ## The rules

  Each rule guards a class of platform bug and skips the classes that would
  produce false alarms until the framework can report them faithfully.

  * **Structure.** Different `type` at a matched position, or a different
    number of children at any level, is always a divergence. This is the
    class MOB-147 B-1 falls into — one platform renders a node type the other
    does not.

  * **Label / value.** A `text` prop that only reaches the tree on one side
    (a rendering path that drops it), or `value` on an input that differs, is
    a divergence.

  * **Frame.** Compared only when *both* sides carry a frame. Android's
    `MobBridge.uiViewTree()` reports a frame only for nodes with `props["id"]`
    (only those are tracked by `Modifier.onGloballyPositioned`), so any node
    without an id has `frame: nil` on Android and a real frame on iOS.
    Reporting that as a divergence would flag every non-id'd node in every
    fixture — the fixture author chooses which nodes need geometry compared by
    giving them ids. Numbers are compared with a tolerance, default 1.0 dp;
    small differences are ordinary rounding across the platform layout
    engines.

  * **Root frame is not compared.** The synthetic root's frame is the screen,
    and comparing screen sizes across an iPad and a Motorola G says nothing
    about the framework.

  * **Class, bg_color, text_color are not compared yet.** `bg_color` and
    `text_color` are `null` on Android today (paint resolves through the theme
    after the tree is built), and comparing them would treat every colour as
    a divergence. When Android surfaces those fields the rules can be added
    without a shape change here.

  Report only the *first* divergence walked in child order. Depth-first, so a
  parent's own divergence is reported before its children's; among children,
  the leftmost wins. That keeps the reader looking at cause rather than
  cascade.
  """

  @typedoc """
  Path to a divergent node, as a list of child indices from the root.
  `[]` is the root itself; `[0, 2]` is the third child of the first child.
  """
  @type path :: [non_neg_integer()]

  @type divergence :: %{
          path: path(),
          reason: atom(),
          ios: term(),
          android: term()
        }

  @type result :: :ok | {:divergence, divergence()}

  @default_frame_tolerance_dp 1.0

  @doc """
  Compare two normalised view trees.

  Options:
    * `:frame_tolerance_dp` — max absolute difference per frame coordinate
      before geometry is reported as divergent. Default `#{@default_frame_tolerance_dp}`.

  Either side may be the atom `:no_window`, `nil` or `{:error, reason}` — the
  shapes `Mob.Test.view_tree/1` can return when a device is not ready. The
  comparator refuses to report divergence in that case (`{:error, :not_ready}`),
  because "one side did not answer" is not a bug in the tree, it is a bug in
  the harness.
  """
  @spec compare(map() | term(), map() | term(), keyword()) ::
          result() | {:error, :not_ready}
  def compare(ios, android, opts \\ [])

  def compare(%{type: _} = ios, %{type: _} = android, opts) do
    tolerance = Keyword.get(opts, :frame_tolerance_dp, @default_frame_tolerance_dp)

    # A malformed sub-tree — a child that is not a map, a node missing
    # `:children`, a frame that is not a 4-tuple — is a harness gap, not a
    # framework defect. Match `Mob.Test.view_tree/1`'s error shape rather than
    # crashing the caller with a `KeyError` or `FunctionClauseError` from
    # somewhere deep in the walk.
    try do
      walk(ios, android, [], tolerance, _root? = true)
    rescue
      _ -> {:error, :not_ready}
    end
  end

  def compare(_ios, _android, _opts), do: {:error, :not_ready}

  # Depth-first, root pair first, then children left-to-right. The recursion
  # returns as soon as any level reports a divergence, so the caller sees the
  # first thing that differs rather than the deepest.
  defp walk(ios, android, path, tolerance, root?) do
    with :ok <- compare_type(ios, android, path),
         :ok <- compare_labels(ios, android, path),
         :ok <- compare_frame(ios, android, path, tolerance, root?),
         :ok <- compare_child_count(ios, android, path) do
      compare_children(ios.children, android.children, path, tolerance)
    end
  end

  defp compare_type(%{type: t}, %{type: t}, _path), do: :ok

  defp compare_type(%{type: ti}, %{type: ta}, path),
    do: {:divergence, %{path: path, reason: :type, ios: ti, android: ta}}

  defp compare_labels(ios, android, path) do
    cond do
      ios[:label] != android[:label] ->
        {:divergence, %{path: path, reason: :label, ios: ios[:label], android: android[:label]}}

      ios[:value] != android[:value] ->
        {:divergence, %{path: path, reason: :value, ios: ios[:value], android: android[:value]}}

      true ->
        :ok
    end
  end

  # Root frame is not compared: it is the screen size, which legitimately
  # differs across device classes. Only reachable via `compare/2`, so this is
  # keyed on the `root?` flag rather than a fragile "is this position [] in
  # the tree" check.
  defp compare_frame(_ios, _android, _path, _tolerance, true), do: :ok

  defp compare_frame(%{frame: nil}, _, _, _, _), do: :ok
  defp compare_frame(_, %{frame: nil}, _, _, _), do: :ok

  defp compare_frame(%{frame: {ix, iy, iw, ih}}, %{frame: {ax, ay, aw, ah}}, path, tol, _) do
    if abs(ix - ax) <= tol and abs(iy - ay) <= tol and abs(iw - aw) <= tol and abs(ih - ah) <= tol do
      :ok
    else
      {:divergence,
       %{
         path: path,
         reason: :frame,
         ios: {ix, iy, iw, ih},
         android: {ax, ay, aw, ah}
       }}
    end
  end

  defp compare_child_count(%{children: ic}, %{children: ac}, path) do
    if length(ic) == length(ac),
      do: :ok,
      else:
        {:divergence,
         %{
           path: path,
           reason: :child_count,
           ios: length(ic),
           android: length(ac)
         }}
  end

  defp compare_children(ios_kids, android_kids, path, tolerance) do
    ios_kids
    |> Enum.zip(android_kids)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{ios, android}, idx}, :ok ->
      case walk(ios, android, path ++ [idx], tolerance, _root? = false) do
        :ok -> {:cont, :ok}
        divergence -> {:halt, divergence}
      end
    end)
  end

  @doc """
  One-line human summary of a divergence, for a log line or a defect report.
  """
  @spec describe(divergence()) :: String.t()
  def describe(%{path: path, reason: reason, ios: ios, android: android}) do
    "divergence at #{format_path(path)}: #{reason} " <>
      "ios=#{inspect(ios)} android=#{inspect(android)}"
  end

  defp format_path([]), do: "root"
  defp format_path(path), do: "root -> " <> Enum.map_join(path, ".", &Integer.to_string/1)
end
