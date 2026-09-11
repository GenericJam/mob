defmodule Mob.PostMortem.RegistryTest do
  # ETS + persistent_term global; async: false.
  use ExUnit.Case, async: false

  alias Mob.PostMortem.Registry

  setup do
    Registry.start()
    Registry.reset()
    :ok
  end

  test "mark_seen/1 returns true on first observation, false on repeat" do
    assert Registry.mark_seen("sha256:abc") == true
    assert Registry.mark_seen("sha256:abc") == false
  end

  test "seen?/1 reflects mark_seen state" do
    refute Registry.seen?("sha256:xyz")
    Registry.mark_seen("sha256:xyz")
    assert Registry.seen?("sha256:xyz")
  end

  test "count/0 tracks distinct ids" do
    assert Registry.count() == 0
    Registry.mark_seen("sha256:a")
    Registry.mark_seen("sha256:b")
    Registry.mark_seen("sha256:a")
    assert Registry.count() == 2
  end

  test "concurrent mark_seen/1 on the same id: exactly one caller wins" do
    id = "sha256:concurrent"
    workers = 20

    results =
      1..workers
      |> Enum.map(fn _ -> Task.async(fn -> Registry.mark_seen(id) end) end)
      |> Enum.map(&Task.await(&1, 1_000))

    # Exactly one true, the rest false — the `:ets.insert_new/2` claim is
    # atomic across concurrent writers. Without atomicity a race could
    # produce two trues and the caller would emit twice for one artifact.
    assert Enum.count(results, & &1) == 1
    assert Enum.count(results, &(&1 == false)) == workers - 1
  end
end
