defmodule Mob.Plugin.SelfTest do
  @moduledoc """
  A plugin's own on-device proof that it works in the host it was built into.

  A plugin declares the module in its manifest (`priv/mob_plugin.exs`):

      %{
        name: :mob_location,
        # ...
        selftest: MobLocation.SelfTest
      }

  and mob_dev's `mix mob.selftest` (or mob_ci, invariant P12) calls
  `run/1` on the device over distribution for every activated plugin. The
  result is attributed to that plugin: a plugin whose self-test fails on its
  own has a bug; one that fails only when other plugins are active has a
  conflict. Without a self-test the ecosystem's CI can only prove that the
  plugin's NIF module loaded, which says nothing about whether `nif_init`
  ran, the Kotlin bridge registered or the Objective-C delegate exists.

  ## The three outcomes

    * `:pass` — the plugin did its job on this device. The test MUST get a
      real answer back from the plugin's native code (a NIF export, a JNI
      bridge call, an Objective-C or Swift entry point) or, for a pure-Elixir
      plugin, from its real API path (a store, a verifier, a client). Loading
      a module, checking `function_exported?/3` or reading config proves
      nothing about the build and does not count. Prefer a side-effect-free
      export: a status query, a version string, a stop/cancel that is a no-op
      while nothing runs. `erlang:nif_error(nif_not_loaded)` from the stub
      means the native library was not linked; that is a `{:fail, _}`.

    * `{:fail, reason}` — the plugin is broken here. `reason` is a sentence
      for a human reading a CI report: say what was called, what came back
      and what was expected. A raise, exit, throw, timeout or a return value
      outside this contract is also counted as a failure by the runner, so a
      test does not need to rescue: `{:ok, _} = :my_nif.status()` is a fine
      assertion.

    * `{:skip, why}` — the test cannot run on this device, not a verdict on
      the plugin. `:needs_hardware` for a sensor, radio or camera this
      device does not have; `:needs_user` when a person must tap a system
      dialog or unlock something; a string for anything else (say what is
      missing). Reach for a skip only after the test has done everything it
      can without that resource: a plugin that can prove its NIF initialised
      and *then* finds no GPS passes; a GPS fix is a feature, not the proof.
      Base `:needs_hardware` on what the native side reports is absent (no
      NFC controller, no LiDAR, no cellular radio), not on
      `device: :emulator` alone: a skip that is really "I did not look"
      hides a hole, and one that assumes a phone has everything fails on
      the tablet without a radio.

  ## The context

  `run/1` receives `%{platform: :ios | :android, device: :simulator |
  :emulator | :physical}` so the test can choose what to prove: a simulator
  has no camera, an emulator has a fake GPS, a physical device usually has
  the hardware but needs the user for permissions. The runner pre-grants the
  permissions the manifest declares on emulators and simulators before
  calling the test, so `:needs_user` is for prompts that cannot be granted
  from the host.

  ## Writing one

      defmodule MobLocation.SelfTest do
        @behaviour Mob.Plugin.SelfTest

        @impl true
        def run(%{platform: platform}) do
          # location_stop/0 is a no-op while no updates run, but it goes
          # through the NIF into CLLocationManager / the Kotlin bridge, so
          # :ok proves the native side is linked and initialised.
          case :mob_location_nif.location_stop() do
            :ok -> :pass
            other -> {:fail, "location_stop/0 on \#{platform} returned \#{inspect(other)}, expected :ok"}
          end
        end
      end

  Keep it under a few seconds: the runner's default timeout is 30 s and the
  test runs once per activated plugin, per device, per nightly cell. Leave
  the device as you found it (stop what you start, delete what you write).
  """

  @typedoc "Where the test is running."
  @type ctx :: %{platform: :ios | :android, device: :simulator | :emulator | :physical}

  @typedoc "Why the test could not run on this device."
  @type skip_reason :: :needs_hardware | :needs_user | String.t()

  @typedoc "What `run/1` returns."
  @type result :: :pass | {:fail, String.t()} | {:skip, skip_reason()}

  @doc """
  Prove the plugin works on this device, or say why that cannot be checked.
  See the module documentation for what each outcome means.
  """
  @callback run(ctx()) :: result()

  @doc """
  Whether `term` is a result `run/1` may return.

  The runner treats anything else as a failure: a test that returns `:ok` or
  `true` has not said whether the plugin works.

      iex> Mob.Plugin.SelfTest.result?(:pass)
      true
      iex> Mob.Plugin.SelfTest.result?({:skip, :needs_hardware})
      true
      iex> Mob.Plugin.SelfTest.result?({:fail, "status/0 returned :error"})
      true
      iex> Mob.Plugin.SelfTest.result?(:ok)
      false
      iex> Mob.Plugin.SelfTest.result?({:skip, :no_reason})
      false
  """
  @spec result?(term()) :: boolean()
  def result?(:pass), do: true
  def result?({:fail, reason}) when is_binary(reason), do: true
  def result?({:skip, reason}) when reason in [:needs_hardware, :needs_user], do: true
  def result?({:skip, reason}) when is_binary(reason), do: true
  def result?(_), do: false
end
