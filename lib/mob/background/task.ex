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

  ## Convenience API

  `run_and_complete/1` wraps the entire lifecycle:

      Mob.Background.Task.run_and_complete(fn ->
        MyApp.Sync.push_all()
        :new_data
      end)

  The function is executed inside a supervised `Task`. When it finishes,
  the completion handler is called automatically with the mapped result.

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
  @type fun_result :: result() | {:ok, any()} | {:error, any()} | any()

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

  @doc """
  Runs `fun` inside a supervised `Task` and auto-completes the current
  background task when `fun` returns.

  Only usable inside an iOS background fetch / silent push callback.
  On Android it always returns `{:ok, "android_bg_task"}`.

  `fun` may return:

    * `:new_data` | `:no_data` | `:failed` — passed directly to the OS
    * `{:ok, _}` or any other value — treated as `:new_data`
    * `{:error, _}` — treated as `:failed`

  If `fun` raises, the completion handler is still called with `:failed`.

  Returns `{:ok, id}` on success, `{:error, :no_background_task}` if
  not inside a background task, or `{:error, reason}` if the task
  process crashes.
  """
  @spec run_and_complete((-> fun_result())) :: {:ok, id()} | {:error, :no_background_task}
  def run_and_complete(fun) when is_function(fun, 0) do
    case :mob_nif.background_task_current() do
      {:ok, id} ->
        task =
          Task.Supervisor.start_child(Mob.TaskSupervisor, fn ->
            try do
              result = fun.()
              mapped = map_result(result)
              complete(id, mapped)
            catch
              _kind, _reason ->
                complete(id, :failed)
            end
          end)

        case task do
          {:ok, _pid} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        {:error, :no_background_task}
    end
  end

  @doc "Complete the current background task with `:new_data`."
  @spec new_data() :: :ok | {:error, :unknown_task | :no_background_task}
  def new_data, do: complete_current(:new_data)

  @doc "Complete the current background task with `:no_data`."
  @spec no_data() :: :ok | {:error, :unknown_task | :no_background_task}
  def no_data, do: complete_current(:no_data)

  @doc "Complete the current background task with `:failed`."
  @spec failed() :: :ok | {:error, :unknown_task | :no_background_task}
  def failed, do: complete_current(:failed)

  defp complete_current(result) do
    case :mob_nif.background_task_current() do
      {:ok, id} -> complete(id, result)
      :none -> {:error, :no_background_task}
    end
  end

  defp map_result(:new_data), do: :new_data
  defp map_result(:no_data), do: :no_data
  defp map_result(:failed), do: :failed
  defp map_result({:error, _}), do: :failed
  defp map_result(_), do: :new_data
end
