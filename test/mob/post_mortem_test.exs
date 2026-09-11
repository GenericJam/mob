defmodule Mob.PostMortemTest do
  use ExUnit.Case, async: false

  alias Mob.Defect.Bus
  alias Mob.PostMortem
  alias Mob.PostMortem.Registry

  @sample_dump """
  =erl_crash_dump:0.5
  Tue Sep  1 14:06:22 2026
  Slogan: Kernel pid terminated (application_controller)
  System version: Erlang/OTP 29 [erts-17.0] [source] [64-bit] [smp:12:12] [jit]
  Taints: crypto
  Atoms: 12000
  Calling Thread: scheduler:1
  """

  setup do
    Bus.start()
    Bus.reset()
    Registry.start()
    Registry.reset()
    {:ok, _} = Bus.subscribe()
    :ok
  end

  test "sweep/1 finds a dump in a caller-supplied path and emits a capsule" do
    tmp = Path.join(System.tmp_dir!(), "post_mortem_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    expected_path = Path.join(tmp, "erl_crash.dump")
    File.write!(expected_path, @sample_dump)

    # `sweep/1` merges default_paths (which include cwd) with the caller's
    # paths, so a stray `erl_crash.dump` in cwd would produce extra
    # capsules and break an unfiltered `[capsule] = capsules` match.
    # Filter to just the dump this test wrote — that isolates the
    # assertion from any environmental contamination.
    capsules =
      [tmp]
      |> PostMortem.sweep()
      |> Enum.filter(&(&1.evidence.path == expected_path))

    assert [capsule] = capsules
    assert capsule.kind == :beam_crash
    assert capsule.owner == :mob
    # "Kernel pid terminated" is one of the fatal-severity strings
    assert capsule.severity == :fatal
    assert capsule.evidence.slogan =~ "application_controller"

    assert_receive {:mob_defect, ^capsule}, 500
  end

  test "sweep/0 is idempotent: a second call with the same on-disk state emits nothing new" do
    # We do not control whether cwd has any dumps under it. Assert only
    # that calling sweep/0 twice in a row cannot produce a strict superset
    # the second time.
    first = PostMortem.sweep()
    second = PostMortem.sweep()

    first_ids = MapSet.new(first, & &1.id)
    second_ids = MapSet.new(second, & &1.id)

    assert MapSet.disjoint?(first_ids, second_ids),
           "the second sweep must not re-emit anything the first already did"

    assert second == []
  end

  test "iOS and Android scaffolds contribute [] and do not error" do
    # Direct call to prove the coordinator's fanout to native modules is
    # tolerant of their empty answers.
    assert Mob.PostMortem.IOS.sweep() == []
    assert Mob.PostMortem.Android.sweep() == []
  end
end
