defmodule Mob.Motion do
  @moduledoc """
  Accelerometer, gyroscope, and magnetometer (compass) sensor data.

  No permission required.

  Updates arrive at `handle_info` at the requested interval:

      handle_info({:motion, %{
        accel:     {ax, ay, az},          # m/s² (gravity included); +g points UP at rest — see below
        gyro:      {gx, gy, gz},          # rad/s
        mag:       {mx, my, mz} | nil,    # µT (microtesla), calibrated — key present only with :magnetometer
        heading:   float | nil,           # degrees [0, 360) from MAGNETIC north — key present only with :magnetometer
        timestamp: unix_ms
      }}, socket)

  ## The `accel` convention

  `accel` is the **specific force** (proper acceleration) in m/s², gravity
  included, in the device's own axes: `+x` right, `+y` toward the top, `+z` out
  of the screen. At rest it reads `+g` (≈ 9.81) on the axis pointing **away from
  the ground** — held upright in portrait, `ay ≈ +9.81`; laid flat face-up,
  `az ≈ +9.81`. Tilt the device and gravity redistributes across the axes; add
  linear motion and it superimposes. This matches Android's `SensorManager`
  `TYPE_ACCELEROMETER`, and iOS is normalized to the same sign and units (its
  raw `CMMotionManager` stream is in G with the opposite gravity sign), so a
  tilt- or shake-driven UI behaves identically on both platforms.

  ## The `:magnetometer` contract

  The `mag` and `heading` keys are present **exactly when you requested
  `:magnetometer`** — on both platforms. When you did, they are **always** in the
  map, and each is `nil` when there's no reading yet: the device has no
  magnetometer at all, or the heading hasn't been fused. So match with `nil`, and
  don't assume a value is present:

      case motion do
        %{heading: deg} when is_number(deg) -> rotate_needle(deg)
        %{heading: nil} -> show_calibration_hint()   # no magnetometer, or not yet fused
      end

  When you did **not** request `:magnetometer`, the map has neither key (the plain
  accel/gyro stream) — so a consumer that never asked for the compass keeps
  getting the exact same 3-key map, and pays no extra sensor/battery cost.

  It's **magnetic** north, not true north — true north needs location + declination
  (out of scope; layer it with `Mob.Location`). Magnetometers drift until
  calibrated, so prompt the user to wave the phone in a figure-8, and note that
  many budget devices ship without one at all (there, `heading`/`mag` stay `nil`).

  iOS: `CMMotionManager` — device motion with the `XMagneticNorthZVertical` reference
  frame when the magnetometer is requested and available (a calibrated field + a
  fused heading on one stream); `nil`/`nil` when requested on a device without one.
  Android: `SensorManager` — magnetometer + rotation-vector, registered only when
  `:magnetometer` is requested.
  """

  @type sensor :: :accelerometer | :gyro | :magnetometer

  @doc """
  Start sensor updates.

  Options:
    - `sensors:` any subset of `[:accelerometer, :gyro, :magnetometer]`
      (default `[:accelerometer, :gyro]`). Add `:magnetometer` for the compass —
      the message then also carries `mag` + `heading`.
    - `interval_ms: integer` — update interval in milliseconds (default `100`)
  """
  @spec start(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start(socket, opts \\ []) do
    {sensors, interval_ms} = parse_opts(opts)
    :mob_nif.motion_start(sensors, interval_ms)
    socket
  end

  @doc false
  # The pure kernel of start/2: resolves opts to the `{sensor_strings, interval_ms}`
  # the NIF expects, applying defaults. Extracted (public, hidden) so the arg
  # building — including that `:magnetometer` survives normalization — is
  # unit-testable without a loaded NIF.
  @spec parse_opts(keyword()) :: {[String.t()], pos_integer()}
  def parse_opts(opts) do
    sensors =
      opts
      |> Keyword.get(:sensors, [:accelerometer, :gyro])
      |> Enum.map(&Atom.to_string/1)

    {sensors, Keyword.get(opts, :interval_ms, 100)}
  end

  @doc """
  Stop sensor updates.
  """
  @spec stop(Mob.Socket.t()) :: Mob.Socket.t()
  def stop(socket) do
    :mob_nif.motion_stop()
    socket
  end
end
