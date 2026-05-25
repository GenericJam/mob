defmodule Mob.Background.Task do
  @moduledoc """
  Completion API for OS background tasks.

  On iOS, the OS can wake the app via silent push (`content-available: 1`)
  or background fetch. Both paths deliver a completion handler that **must**
  be called within ~30 seconds or the OS rate-limits future background
  execution.

  The native side (AppDelegate) generates a UUID for each task, stores the
  completion handler, and sends a message to the BEAM:

      {:background_task, id, type, payload, deadline_us}

  where:

    * `id` — UUID string
    * `type` — `:silent_push` or `:background_fetch`
    * `payload` — JSON string from the APNS userInfo, or `nil`
    * `deadline_us` — monotonic microseconds by which `complete/2` must be called

  The receiving process (usually a `GenServer`) does the work and then
  calls `complete/2` to signal the OS:

      Mob.Background.Task.complete(id, :new_data)

  ## Example

      def handle_info({:background_task, id, :silent_push, _payload, _deadline}, state) do
        Task.start(fn ->
          MyApp.Sync.push_all()
          Mob.Background.Task.complete(id, :new_data)
        end)
        {:noreply, state}
      end

  ## Safe-fail behaviour

  If `complete/2` is called with an unknown ID (e.g. the task already
  timed out), it returns `{:error, :unknown_task}`.  Calling it twice
  for the same ID is also safe — the second call returns the same error.

  On Android the concept of a completion handler does not exist for FCM
  data messages, so this module is currently a no-op on Android.
  """

  @type result :: :new_data | :no_data | :failed
  @type id :: String.t()

  @doc """
  Signals that the background task identified by `id` is finished.

  `result` tells the OS whether new data was fetched:

    * `:new_data` — the app fetched new data; OS may refresh UI
    * `:no_data` — nothing changed
    * `:failed` — transient error; OS may retry sooner

  Returns `:ok` on success or `{:error, :unknown_task}` if the ID is
  not recognised (already completed or timed out).
  """
  @spec complete(id(), result()) :: :ok | {:error, :unknown_task}
  def complete(id, result) when result in [:new_data, :no_data, :failed] and is_binary(id) do
    :mob_nif.background_task_complete(id, result)
  end
end
