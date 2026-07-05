defmodule Mob.Torch do
  @moduledoc """
  Rear-camera torch (flashlight) on/off. No permission required on either
  platform — the torch is toggled directly, without opening a camera session.

  ## Usage

      def handle_event("toggle_light", _params, socket) do
        on? = not socket.assigns.light_on
        {:noreply, socket |> Mob.Torch.set(on?) |> assign(:light_on, on?)}
      end

  `on/1` and `off/1` are conveniences over `set/2`.

  On a device with **no rear flash** (most tablets, the iOS simulator) this is a
  **no-op, not an error** — check the hardware yourself if you need to hide the
  control. The torch is a shared hardware resource: the OS turns it off when the
  app is backgrounded, and an active camera capture can override it. This module
  is fire-and-forget and does not read the state back — the app owns the on/off
  boolean and should re-assert it after resuming if it needs to persist.

  iOS: `AVCaptureDevice.torchMode` via `lockForConfiguration`. Android:
  `CameraManager.setTorchMode` on the rear camera that reports a flash unit.
  """

  @doc "Turn the torch on. Returns the socket unchanged."
  @spec on(Mob.Socket.t()) :: Mob.Socket.t()
  def on(socket), do: set(socket, true)

  @doc "Turn the torch off. Returns the socket unchanged."
  @spec off(Mob.Socket.t()) :: Mob.Socket.t()
  def off(socket), do: set(socket, false)

  @doc """
  Set the torch on (`true`) or off (`false`). Returns the socket unchanged so it
  can be used inline in a `handle_event`/`handle_info` return.
  """
  @spec set(Mob.Socket.t(), boolean()) :: Mob.Socket.t()
  def set(socket, on?) when is_boolean(on?) do
    :mob_nif.torch(state_atom(on?))
    socket
  end

  @doc false
  # The wire atom the NIF expects for a given on/off boolean. Public (hidden) so
  # the mapping is unit-testable without a loaded NIF.
  @spec state_atom(boolean()) :: :on | :off
  def state_atom(true), do: :on
  def state_atom(false), do: :off
end
