defmodule Mob.Agent.Receipt do
  @moduledoc """
  What one action did, and which layer is answerable if it did nothing.

  An agent driving a Mob app can already ask "what are the assigns now". It
  cannot ask "did *my* tap cause that". The difference matters more than it
  sounds: the effect detector behind `tap_xy/3` waits 300ms for a process-wide
  event counter to move, so any Mob event inside that window — a timer, a scroll
  notification, another agent on the same device — is indistinguishable from the
  tap landing. It reports success for taps that did nothing, and on 2026-09-04 it
  reported `{:error, :no_effect}` for a tap that demonstrably worked.

  A receipt replaces the window with a correlation id. One action, one id,
  followed from dispatch through to the committed frame.

  ## The five stages

  An action passes through five observable stages, and the *first* one it fails
  to reach names the layer at fault. That is the whole point of recording them
  separately rather than reporting a boolean:

  | Stage | Reached when | If it stops here |
  |---|---|---|
  | `:dispatched` | the screen received the event | — |
  | `:unhandled` | *no* clause matched the event | event routing — a stale tag, a renamed event |
  | `:handled` | `handle_event/3` returned | — it raised; see `:unhandled` below |
  | `:assigns_changed` | the socket's assigns differ | application code — the handler ran and decided nothing |
  | `:frame_changed` | `render/1` produced a different frame | the render function — it ignores the assigns that changed |
  | `:committed` | the frame was handed to the sender | the renderer or the bridge |
  | `:navigated` | the handler asked for a navigation | — this screen does not paint; the destination does |

  `:frame_changed` rather than `:tree_changed` because the fingerprint covers
  `{tree, Mob.Theme.current()}` — a handler that changes only the theme produces
  an identical tree and a different frame, and calling that "the tree changed"
  would be false.

  This is why `owner/1` is computable rather than guessed. A defect report that
  says "the tap did nothing" is a bug report nobody can route; one that says
  "the handler ran and changed `:count`, and the tree did not change" points at a
  `render/1` that never reads `:count`.

  ## What this does not know

  A `render/1` that raises produces **no receipt**. The exception escapes from
  the paint, which happens after the callback returned, outside the `try` that
  wraps it — so the textbook `:render_function` defect is the one case with no
  record. Covering it means wrapping the paint, which would change what a
  render crash does to the screen, and that is a bigger decision than this
  slice.

  `native_commit` is `:unknown` on a receipt assembled from the BEAM alone.
  Handing a frame to `Mob.Sender` is not proof the platform drew it, and the
  native acknowledgement is not wired yet. A receipt says what the BEAM did; it
  does not claim the pixels changed. Anything stronger would be the same
  overclaim the process-wide counter makes, in better clothes.
  """

  @type stage ::
          :dispatched
          | :unhandled
          | :handled
          | :assigns_changed
          | :frame_changed
          | :committed
          | :navigated

  @typedoc """
  A crash, reduced to what is safe to keep.

  Never the exception struct. Standard exceptions embed the term that failed —
  `KeyError.term`, `MatchError.term`, `BadMapError.term` — so a `Map.fetch!/2`
  against assigns puts the whole assigns map, secrets included, into the
  receipt. That is exactly MOB-147's leak, and a receipt is written to ETS and
  handed to telemetry, so it reaches a sink.
  """
  @type error_summary :: %{
          kind: :error | :exit | :throw,
          exception: module() | nil,
          message: String.t() | nil,
          at: mfa() | nil,
          redaction: :applied
        }
  @type owner :: :event_routing | :app_code | :render_function | :renderer | :none

  @type t :: %__MODULE__{
          action_id: String.t(),
          screen: module() | nil,
          handler: mfa() | nil,
          event: term(),
          stages: [stage()],
          before_frame_fingerprint: non_neg_integer() | nil,
          after_frame_fingerprint: non_neg_integer() | nil,
          native_commit: :unknown | :acknowledged | :rejected,
          error: error_summary() | nil,
          elapsed_us: non_neg_integer() | nil,
          monotonic_us: integer() | nil
        }

  defstruct action_id: nil,
            screen: nil,
            handler: nil,
            event: nil,
            stages: [],
            before_frame_fingerprint: nil,
            after_frame_fingerprint: nil,
            native_commit: :unknown,
            error: nil,
            elapsed_us: nil,
            monotonic_us: nil

  @doc """
  A fresh correlation id.

  Unique within the node and cheap: this is on the path of every dispatched
  event, so it must not be a bottleneck or a source of entropy exhaustion.
  """
  @spec new_action_id() :: String.t()
  def new_action_id do
    Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  @doc """
  Did this action reach `stage`?
  """
  @spec reached?(t(), stage()) :: boolean()
  def reached?(%__MODULE__{stages: stages}, stage), do: stage in stages

  @doc """
  True when `error` is "no clause matched `handle_event/3` on this screen".

  Distinct from a crash *inside* a handler, and the distinction is the whole
  reason `:event_routing` and `:app_code` are separate owners. An event that
  reached the screen and matched nothing is a routing problem — a tag that no
  longer exists, a renamed event — and sending someone to read the handler body
  wastes their time. `use Mob.Screen` supplies no catch-all, so this arrives as
  a `FunctionClauseError` naming the function it failed to match.
  """
  @spec unmatched_event?(term(), module()) :: boolean()
  def unmatched_event?({:error, %Mob.Screen.UnhandledEventError{}}, _screen), do: true

  def unmatched_event?({:error, %FunctionClauseError{} = e}, screen) do
    e.module == screen and e.function == :handle_event and e.arity == 3
  end

  def unmatched_event?(_error, _screen), do: false

  # Exceptions whose message is built from framework-controlled values only.
  # Everything else is assumed to embed application state, because most standard
  # exceptions do — and not only in a struct field: `KeyError`'s *message* is
  # "key :x not found in: %{...}", so truncating the rendered message does not
  # help. Default-deny is the only posture consistent with the sink policy in
  # `decisions/2026-09-04-defect-reports-are-a-shipped-feature.md`, which
  # excludes assigns by default and allows `redaction: "none"` only for a report
  # that provably contains no application state.
  @safe_message_exceptions [Mob.Screen.UnhandledEventError]

  @doc """
  Reduce a raised exception to a summary that cannot carry application state.

  Keeps the kind, the exception module, and the top stack frame — enough to
  route a defect ("a `KeyError` in `MyScreen.handle_event/3`") without carrying
  a single value out of the socket.

  The **message is dropped** unless the exception is one whose message the
  framework builds itself. This is deliberate and costs real diagnostic detail:
  a `RuntimeError`'s message is usually the most useful line in the report. But
  app code writes `raise "failed for \#{inspect(user)}"` as a matter of routine,
  and a receipt is written to ETS and handed to telemetry — a sink. Carrying it
  would re-create MOB-147's `SecureField` leak in the mitigation named after it.
  """
  @spec summarize_error(:error | :exit | :throw, term(), Exception.stacktrace()) ::
          error_summary()
  def summarize_error(kind, reason, stacktrace) do
    exception = if is_exception(reason), do: reason.__struct__

    %{
      kind: kind,
      exception: exception,
      message: safe_message(exception, reason),
      at: top_mfa(stacktrace),
      redaction: :applied
    }
  end

  defp safe_message(exception, reason) when exception in @safe_message_exceptions,
    do: reason |> Exception.message() |> String.slice(0, 512)

  defp safe_message(_exception, _reason), do: nil

  defp top_mfa([{m, f, a, _loc} | _]) when is_integer(a), do: {m, f, a}
  defp top_mfa([{m, f, a, _loc} | _]) when is_list(a), do: {m, f, length(a)}
  defp top_mfa(_), do: nil

  @doc """
  The layer answerable for this action producing no visible change.

  `:none` when the action committed a changed frame — nothing to answer for.

  A raise is attributed to `:app_code` — a crash in a callback is the
  application's, and the stage list would otherwise blame whichever layer
  happened to come next — unless it is the "no clause matched" raise, which is
  routing.
  """
  @spec owner(t()) :: owner()
  def owner(%__MODULE__{error: error, stages: stages}) when not is_nil(error) do
    if :unhandled in stages, do: :event_routing, else: :app_code
  end

  def owner(%__MODULE__{stages: stages}) do
    cond do
      # A handler that navigated did the most visible thing an action can do.
      # The destination screen paints; this one deliberately does not.
      :navigated in stages -> :none
      :frame_changed in stages and :committed in stages -> :none
      :frame_changed in stages -> :renderer
      :assigns_changed in stages -> :render_function
      :handled in stages -> :app_code
      true -> :event_routing
    end
  end

  @doc """
  The verdict an agent asked "did my action do anything" wants.

  * `:verified` — a changed frame was committed.
  * `:navigated` — the handler asked for a navigation. The most visible thing an
    action can do, and it is reported separately because this screen
    deliberately does not paint: the owner applies the action and the
    destination paints. Reporting it from the absence of a paint would call the
    commonest successful action in a mobile app "inert", which is the same lie
    the process-wide counter tells, in the other direction.
  * `:no_visible_change` — the handler ran and the frame came out identical.
  * `:not_committed` — a new frame was built and never handed to the sender.
  * `:inert` — the handler ran and changed nothing.
  * `:unhandled` — no clause matched the event.
  * `:error` — the handler raised.

  `:no_visible_change` is deliberately not an error. A handler that toggles a
  value the current screen does not render has done exactly what it was asked;
  whether that is a bug is the caller's judgement, and a framework that decides
  it for them produces false failures.
  """
  @spec effect(t()) ::
          :verified
          | :navigated
          | :no_visible_change
          | :not_committed
          | :inert
          | :unhandled
          | :error
  def effect(%__MODULE__{error: error, stages: stages}) when not is_nil(error) do
    if :unhandled in stages, do: :unhandled, else: :error
  end

  def effect(%__MODULE__{stages: stages}) do
    cond do
      :navigated in stages -> :navigated
      :frame_changed in stages and :committed in stages -> :verified
      :frame_changed in stages -> :not_committed
      :assigns_changed in stages -> :no_visible_change
      :handled in stages -> :inert
      true -> :unhandled
    end
  end

  @doc """
  A one-line summary for a human reading a triage log.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = receipt) do
    handler =
      case receipt.handler do
        {m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
        nil -> "(no handler)"
      end

    "#{receipt.action_id} #{inspect(receipt.event)} → #{handler} " <>
      "= #{effect(receipt)} (owner: #{owner(receipt)}, #{receipt.elapsed_us || 0}us)"
  end
end
