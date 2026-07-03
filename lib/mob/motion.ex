defmodule Mob.Motion do
  @moduledoc """
  Accelerometer, gyroscope, and magnetometer (compass) sensor data.

  No permission required.

  Updates arrive at `handle_info` at the requested interval:

      handle_info({:motion, %{
        accel:     {ax, ay, az},   # m/s² (gravity included)
        gyro:      {gx, gy, gz},   # rad/s
        mag:       {mx, my, mz},   # µT (microtesla), calibrated — present only when :magnetometer requested
        heading:   float | nil,    # degrees [0, 360) from MAGNETIC north — present only with :magnetometer
        timestamp: unix_ms
      }}, socket)

  `mag` and `heading` appear **only when you request `:magnetometer`** (the plain
  accel/gyro stream is unchanged). `heading` is `nil` on a device with no
  magnetometer. It's **magnetic** north, not true north — true north needs location
  + declination (out of scope; layer it with `Mob.Location`). Magnetometers drift
  until calibrated, so prompt the user to wave the phone in a figure-8, and note
  that many budget devices ship without one at all.

  iOS: `CMMotionManager` — device motion with the `XMagneticNorthZVertical` reference
  frame when the magnetometer is requested (gives a calibrated field + a fused
  heading on the same stream). Android: `SensorManager`.
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
