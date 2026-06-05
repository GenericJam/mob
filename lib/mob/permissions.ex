defmodule Mob.Permissions do
  @moduledoc """
  Request OS-level permissions from the user.

  The permission dialog is shown asynchronously. The result arrives as:

      handle_info({:permission, capability, :granted | :denied}, socket)

  Capabilities that core handles directly:
    - `:camera`
    - `:microphone`
    - `:photo_library`
    - `:notifications`

  Plugins can add their own capabilities (e.g. a `mob_location` plugin owns
  `:location`): the plugin registers a native handler that the platform
  permission registry dispatches to. `request/2` therefore accepts any atom and
  lets the native layer decide whether it is a known capability — an unrecognized
  one returns `badarg` from the NIF (surfacing as an `ArgumentError`).

  Capabilities that need *no* permission: haptics, clipboard, share sheet, file picker.

  > **Beyond `request/2`**: each capability also needs a matching
  > `Info.plist` key (iOS) and `AndroidManifest.xml` entry. Without
  > them the dialog is silently suppressed and you get no event. See
  > the [permissions guide](permissions.html) for the per-capability
  > table and the most common failure modes — it's the first place
  > to check when "the dialog never appears".
  """

  @typedoc """
  A permission capability. The atoms core handles directly are listed below;
  plugins may register additional capabilities at runtime, so any atom is
  accepted by `request/2` and validated natively.
  """
  @type capability :: :camera | :microphone | :photo_library | :notifications | atom()

  @doc """
  Request an OS permission from the user.

  The system dialog is shown asynchronously. The result arrives in
  `handle_info/2`:

      def handle_info({:permission, :camera, :granted}, socket), do: ...
      def handle_info({:permission, :camera, :denied},  socket), do: ...

  Safe to call if the permission is already granted — the result still arrives
  via `handle_info` with the current status.

  The capability must be one core handles or one a plugin has registered. A
  capability that needs no permission (haptics, clipboard, share sheet, file
  picker) — or any other unrecognized atom — returns `badarg` from the NIF,
  surfacing as an `ArgumentError`; do not call `request/2` for those.
  """
  @spec request(Mob.Socket.t(), capability()) :: Mob.Socket.t()
  def request(socket, capability) when is_atom(capability) do
    :mob_nif.request_permission(capability)
    socket
  end
end
