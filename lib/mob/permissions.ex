defmodule Mob.Permissions do
  @moduledoc """
  Request OS-level permissions from the user.

  The permission dialog is shown asynchronously. The result arrives as:

      handle_info({:permission, capability, :granted | :denied}, socket)

  Capabilities that require this:
    - `:camera`
    - `:microphone`
    - `:photo_library`
    - `:location`
    - `:notifications`

  Capabilities that need *no* permission: haptics, clipboard, share sheet, file picker.

  > **Beyond `request/2`**: each capability also needs a matching
  > `Info.plist` key (iOS) and `AndroidManifest.xml` entry. Without
  > them the dialog is silently suppressed and you get no event. See
  > the [permissions guide](permissions.html) for the per-capability
  > table and the most common failure modes — it's the first place
  > to check when "the dialog never appears".
  """

  @type capability :: :camera | :microphone | :photo_library | :location | :notifications

  @doc """
  Request an OS permission from the user.

  The system dialog is shown asynchronously. The result arrives in
  `handle_info/2`:

      def handle_info({:permission, :camera, :granted}, socket), do: ...
      def handle_info({:permission, :camera, :denied},  socket), do: ...

  Safe to call if the permission is already granted — the result still arrives
  via `handle_info` with the current status.

  Capabilities that do not require permission (haptics, clipboard, share sheet,
  file picker) will raise `FunctionClauseError` — do not call `request/2` for them.
  """
  @spec request(Mob.Socket.t(), capability()) :: Mob.Socket.t()
  def request(socket, capability)
      when capability in [:camera, :microphone, :photo_library, :location, :notifications] do
    :mob_nif.request_permission(capability)
    socket
  end
end
