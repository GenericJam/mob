defmodule Mob.Notification do
  @moduledoc """
  The `{:notification, notification}` message a screen receives when a
  notification arrives or is tapped, on both platforms.

      def handle_info({:notification, %{presentation: :tap, data: data}}, socket) do
        {:noreply, Mob.Socket.push_screen(socket, MyApp.ThreadScreen, data)}
      end

      # Arrived while the app was open; the OS still shows its banner.
      def handle_info({:notification, %{presentation: :foreground}}, socket) do
        {:noreply, socket}
      end

  ## Fields

    * `:presentation` — `:foreground` when the notification arrived while the
      app was in the foreground, `:tap` when the user opened it from the
      banner or notification centre, including the tap that launched the app
      from a killed state.
    * `:action` — for a `:tap`, `"default"` for a tap on the notification
      itself. An app that registers its own notification categories also sees
      `"dismiss"` and its own action identifiers here (iOS). `nil` for
      `:foreground`.
    * `:source` — `:push` for a remote notification, `:local` for one
      scheduled on the device.
    * `:id` — the notification's identifier (the `id:` given to
      `MobNotify.schedule/2`), or `nil`.
    * `:title`, `:body` — the displayed text, or `nil`.
    * `:data` — the custom payload: `data:` from `MobNotify.schedule/2`, or
      the custom keys of a push payload (iOS's `aps` dictionary is not
      included). Top-level keys are atoms; nested values are as JSON decodes
      them (maps with string keys, lists, numbers, booleans, `nil`).

  ## Where it is delivered

  To the process that registered for notifications through `mob_notify`
  (`MobNotify.register_push/1`, or `MobNotify.schedule/2` on iOS) while it is
  alive. Otherwise to the screen currently showing. A tap that launches the
  app arrives at the root screen once it has mounted, exactly once.

  Each native layer serialises the notification to one JSON envelope and hands
  it to the `:mob_screen` router, which decodes it with `decode/1`. That keeps
  the shape in one place rather than one per platform; see
  `decisions/2026-10-01-notification-delivery-envelope.md`.
  """

  @type t :: %{
          id: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          data: map(),
          source: :local | :push,
          presentation: :foreground | :tap,
          action: String.t() | nil
        }

  @doc """
  Decodes the JSON envelope native code hands to the router.

  `presentation` defaults to `"tap"` when absent: app-owned Android code
  generated before it existed sends only taps, and so does any caller of the
  iOS `mob_set_launch_notification_json/1` hook.
  """
  @spec decode(binary()) ::
          {:ok, t()} | {:error, :invalid_json | :not_an_object | :data_key_too_long}
  def decode(json) when is_binary(json) do
    with {:ok, map} when is_map(map) <- JSON.decode(json),
         {:ok, data} <- data(Map.get(map, "data")) do
      {:ok, from_envelope(map, data)}
    else
      {:ok, _not_a_map} -> {:error, :not_an_object}
      {:error, :data_key_too_long} = error -> error
      {:error, _json_error} -> {:error, :invalid_json}
    end
  end

  defp from_envelope(map, data) do
    presentation =
      case Map.get(map, "presentation") do
        "foreground" -> :foreground
        _ -> :tap
      end

    %{
      id: string_or_nil(map, "id"),
      title: string_or_nil(map, "title"),
      body: string_or_nil(map, "body"),
      data: data,
      source: if(Map.get(map, "source") == "push", do: :push, else: :local),
      presentation: presentation,
      action: action(presentation, Map.get(map, "action"))
    }
  end

  defp string_or_nil(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # Atom keys match what screens have always pattern-matched on (the iOS
  # delegate built atom-keyed maps natively). The keys come from the app's own
  # schedule call or its own push server, not from arbitrary input. An atom
  # holds at most 255 characters and String.to_atom/1 raises past that, which
  # in the router would take every screen down with it.
  defp data(map) when is_map(map) do
    if Enum.all?(map, fn {key, _} -> Enum.count_until(String.to_charlist(key), 256) <= 255 end) do
      {:ok, Map.new(map, fn {key, value} -> {String.to_atom(key), value} end)}
    else
      {:error, :data_key_too_long}
    end
  end

  defp data(_), do: {:ok, %{}}

  defp action(:foreground, _), do: nil
  defp action(:tap, action) when is_binary(action) and action != "", do: action
  defp action(:tap, _), do: "default"
end
