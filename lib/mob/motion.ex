defmodule Mob.Motion do
  @moduledoc """
  Accelerometer and gyroscope sensor data.

  No permission required.

  Updates arrive at `handle_info` at the requested interval:

      handle_info({:motion, %{
        accel:     {ax, ay, az},   # m/s² (gravity included)
        gyro:      {gx, gy, gz},   # rad/s
        timestamp: unix_ms
      }}, socket)

  If you only request one sensor, the other tuple will be `{0.0, 0.0, 0.0}`.

  iOS: `CMMotionManager`. Android: `SensorManager`.
  """

  @type sensor :: :accelerometer | :gyro

  @doc """
  Start sensor updates.

  Options:
    - `sensors: [:accelerometer] | [:gyro] | [:accelerometer, :gyro]` (default both)
    - `interval_ms: integer` — update interval in milliseconds (default `100`)
  """
  @spec start(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start(socket, opts \\ []) do
    sensors =
      Keyword.get(opts, :sensors, [:accelerometer, :gyro])
      |> Enum.map(&Atom.to_string/1)

    interval_ms = Keyword.get(opts, :interval_ms, 100)
    :mob_nif.motion_start(sensors, interval_ms)
    socket
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
