defmodule Mob.Plugin.SelfTestTest do
  use ExUnit.Case, async: true

  alias Mob.Plugin.SelfTest

  doctest SelfTest

  defmodule Probe do
    @moduledoc false
    @behaviour Mob.Plugin.SelfTest

    @impl true
    def run(%{platform: :ios, device: :simulator}), do: {:skip, :needs_hardware}
    def run(%{platform: platform}), do: {:fail, "no native code on #{platform}"}
  end

  test "the behaviour asks for run/1 only" do
    assert SelfTest.behaviour_info(:callbacks) == [run: 1]
    assert SelfTest.behaviour_info(:optional_callbacks) == []
  end

  test "an implementation answers per context with a result the runner accepts" do
    sim = Probe.run(%{platform: :ios, device: :simulator})
    phone = Probe.run(%{platform: :android, device: :physical})

    assert sim == {:skip, :needs_hardware}
    assert phone == {:fail, "no native code on android"}
    assert SelfTest.result?(sim) and SelfTest.result?(phone)
  end

  test "result?/1 rejects shapes outside the contract" do
    refute SelfTest.result?({:fail, :nif_not_loaded})
    refute SelfTest.result?({:skip, nil})
    refute SelfTest.result?({:pass, "extra"})
    refute SelfTest.result?(true)
  end
end
