defmodule Mob.Onboarding.DeviceManager do
  @moduledoc """
  Programmatic lifecycle management for iOS simulators and Android emulators.

  Each test run creates devices with a unique name derived from the run ID so
  parallel runs never share state. Devices are always torn down after the test,
  whether it passed or failed.

  ## iOS

  Uses `xcrun simctl`. Requires Xcode to be installed and a command-line tools
  licence accepted (`sudo xcode-select --install`).

  ## Android

  Uses `avdmanager` + `emulator` + `adb`. Requires Android SDK installed with
  `sdkmanager`, `emulator`, and `platform-tools` packages.

  Emulators run headless (`-no-window`) and use swiftshader GPU for CI
  compatibility. Each run gets a dedicated ADB port so parallel runs don't
  collide.
  """

  require Logger

  # ── Types ─────────────────────────────────────────────────────────────────────

  @type sim_id :: String.t()
  @type avd_name :: String.t()
  @type adb_serial :: String.t()

  @type ios_device :: %{
          sim_id: sim_id(),
          runtime: String.t(),
          device_type: String.t()
        }

  @type android_device :: %{
          avd_name: avd_name(),
          adb_serial: adb_serial(),
          api_level: pos_integer(),
          port: pos_integer(),
          os_pid: pos_integer() | nil
        }

  # ── iOS ───────────────────────────────────────────────────────────────────────

  @ios_runtimes %{
    ios_min: "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
    ios_max: "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
  }

  @ios_device_types %{
    ios_min: "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation",
    ios_max: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"
  }

  @doc """
  Create and boot a fresh iOS simulator. Returns the device map.

  `slot` is `:ios_min` or `:ios_max`.
  """
  @spec create_ios(String.t(), :ios_min | :ios_max) :: {:ok, ios_device()} | {:error, String.t()}
  def create_ios(run_id, slot) do
    runtime = @ios_runtimes[slot]
    device_type = @ios_device_types[slot]
    name = "mob-onboarding-#{run_id}-#{slot}"

    with :ok <- ensure_ios_runtime(runtime),
         {:ok, sim_id} <- simctl_create(name, device_type, runtime),
         :ok <- simctl_boot(sim_id) do
      {:ok, %{sim_id: sim_id, runtime: runtime, device_type: device_type}}
    end
  end

  @doc "Shut down and delete an iOS simulator."
  @spec destroy_ios(ios_device()) :: :ok
  def destroy_ios(%{sim_id: sim_id}) do
    simctl("shutdown #{sim_id}")
    :timer.sleep(1_000)
    simctl("delete #{sim_id}")
    :ok
  end

  @doc "Returns the node name the iOS simulator BEAM will register as."
  def ios_node_name(app_name), do: :"#{app_name}_ios@127.0.0.1"

  # ── Android ───────────────────────────────────────────────────────────────────

  @android_images %{
    android_min: %{api: 28, tag: "google_apis", abi: "arm64-v8a"},
    android_max: %{api: 35, tag: "google_apis", abi: "arm64-v8a"}
  }

  # Base port — each run_index offsets by 2 (ADB uses port+1 for ADB itself)
  @base_emulator_port 5554

  @doc """
  Create, start, and wait for an Android emulator to be fully booted.

  `run_index` is a small integer (0, 1, 2…) used to assign a unique port.
  `slot` is `:android_min` or `:android_max`.
  """
  @spec create_android(String.t(), non_neg_integer(), :android_min | :android_max) ::
          {:ok, android_device()} | {:error, String.t()}
  def create_android(run_id, run_index, slot) do
    %{api: api, tag: tag, abi: abi} = @android_images[slot]
    avd_name = "mob_onboarding_#{run_id}_#{slot}"
    port = @base_emulator_port + run_index * 2
    adb_serial = "emulator-#{port}"
    image_pkg = "system-images;android-#{api};#{tag};#{abi}"

    with :ok <- ensure_android_image(image_pkg),
         :ok <- avd_create(avd_name, image_pkg),
         {:ok, os_pid} <- emulator_start(avd_name, port),
         :ok <- adb_wait_boot(adb_serial, 180_000) do
      {:ok,
       %{avd_name: avd_name, adb_serial: adb_serial, api_level: api, port: port, os_pid: os_pid}}
    end
  end

  @doc "Kill and delete an Android emulator."
  @spec destroy_android(android_device()) :: :ok
  def destroy_android(%{adb_serial: serial, avd_name: avd, os_pid: pid}) do
    adb(serial, "emu kill")
    if pid, do: :timer.sleep(2_000)
    if pid, do: System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    avd_delete(avd)
    :ok
  end

  @doc "Returns the node name the Android BEAM will register as."
  def android_node_name(app_name), do: :"#{app_name}_android@127.0.0.1"

  # ── iOS internals ─────────────────────────────────────────────────────────────

  defp ensure_ios_runtime(runtime) do
    case simctl("list runtimes") do
      {:ok, output} ->
        if String.contains?(output, runtime) do
          :ok
        else
          Logger.info("Downloading iOS runtime #{runtime}…")

          case simctl("runtime add #{runtime}", timeout: 600_000) do
            {:ok, _} -> :ok
            {:error, e} -> {:error, "Could not download iOS runtime #{runtime}: #{e}"}
          end
        end

      {:error, e} ->
        {:error, e}
    end
  end

  defp simctl_create(name, device_type, runtime) do
    case simctl("create #{inspect(name)} #{inspect(device_type)} #{inspect(runtime)}") do
      {:ok, output} ->
        sim_id = output |> String.trim()

        if String.length(sim_id) == 36,
          do: {:ok, sim_id},
          else: {:error, "Unexpected simctl create output: #{output}"}

      {:error, e} ->
        {:error, e}
    end
  end

  defp simctl_boot(sim_id) do
    case simctl("boot #{sim_id}") do
      {:ok, _} -> wait_for_sim_boot(sim_id, 60_000)
      {:error, e} -> {:error, e}
    end
  end

  defp wait_for_sim_boot(sim_id, deadline) when deadline <= 0 do
    {:error, "Simulator #{sim_id} did not reach Booted state within timeout"}
  end

  defp wait_for_sim_boot(sim_id, remaining) do
    case simctl("list devices") do
      {:ok, output} ->
        if output =~ ~r/#{sim_id}.*Booted/ do
          :ok
        else
          :timer.sleep(1_000)
          wait_for_sim_boot(sim_id, remaining - 1_000)
        end

      {:error, _} ->
        :timer.sleep(1_000)
        wait_for_sim_boot(sim_id, remaining - 1_000)
    end
  end

  defp simctl(subcommand, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case System.cmd("xcrun", ["simctl" | String.split(subcommand)],
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "xcrun simctl #{subcommand} exited #{code}: #{output}"}
    end
  end

  # ── Android internals ─────────────────────────────────────────────────────────

  defp ensure_android_image(package) do
    sdk_root = android_sdk_root()
    image_dir = Path.join([sdk_root, "system-images" | String.split(package, ";")])

    if File.dir?(image_dir) do
      :ok
    else
      Logger.info("Downloading Android system image #{package}…")

      case System.cmd("sdkmanager", [package],
             stderr_to_stdout: true,
             env: [{"ANDROID_HOME", sdk_root}]
           ) do
        {_, 0} -> :ok
        {output, c} -> {:error, "sdkmanager failed (#{c}): #{output}"}
      end
    end
  end

  defp avd_create(name, image_pkg) do
    # Delete existing AVD with same name if it exists
    avd_delete(name)

    case System.cmd(
           "avdmanager",
           [
             "create",
             "avd",
             "--name",
             name,
             "--package",
             image_pkg,
             "--device",
             "pixel_6",
             "--force"
           ],
           input: "no\n",
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, c} -> {:error, "avdmanager create avd failed (#{c}): #{output}"}
    end
  end

  defp avd_delete(name) do
    System.cmd("avdmanager", ["delete", "avd", "--name", name], stderr_to_stdout: true)
    :ok
  end

  defp emulator_start(avd_name, port) do
    sdk_root = android_sdk_root()
    emulator = Path.join([sdk_root, "emulator", "emulator"])

    args = [
      "-avd",
      avd_name,
      "-port",
      "#{port}",
      "-no-window",
      "-no-audio",
      "-no-boot-anim",
      "-gpu",
      "swiftshader_indirect"
    ]

    # Start detached so the test process doesn't block
    case :os.cmd(String.to_charlist("#{emulator} #{Enum.join(args, " ")} &")) do
      _output ->
        # Give the emulator a moment to register a PID
        :timer.sleep(2_000)
        {:ok, find_emulator_pid(avd_name)}
    end
  end

  defp find_emulator_pid(avd_name) do
    case System.cmd("pgrep", ["-f", "emulator.*#{avd_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.trim() |> String.split("\n") |> List.first() |> String.to_integer()

      _ ->
        nil
    end
  end

  defp adb_wait_boot(serial, deadline) when deadline <= 0 do
    {:error, "Android emulator #{serial} did not finish booting within timeout"}
  end

  defp adb_wait_boot(serial, remaining) do
    case System.cmd("adb", ["-s", serial, "shell", "getprop", "sys.boot_completed"],
           stderr_to_stdout: true
         ) do
      {"1\n", 0} ->
        # Extra wait for the window manager to settle before install/launch
        :timer.sleep(3_000)
        :ok

      _ ->
        :timer.sleep(2_000)
        adb_wait_boot(serial, remaining - 2_000)
    end
  end

  defp adb(serial, subcommand) do
    System.cmd("adb", ["-s", serial | String.split(subcommand)], stderr_to_stdout: true)
  end

  defp android_sdk_root do
    System.get_env("ANDROID_HOME") ||
      System.get_env("ANDROID_SDK_ROOT") ||
      Path.join([System.get_env("HOME", "~"), "Library", "Android", "sdk"])
  end
end
