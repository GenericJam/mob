defmodule Mob.CrashReport do
  @moduledoc false
  # MOB-310. What a screen or component crash writes to the log, reduced to
  # terms that cannot carry application state. On a device the log is logcat or
  # NSLog, readable by adb and attached to bug reports, in release builds too.
  #
  # Every channel had a copy of the socket: a `FunctionClauseError`'s stack
  # frame holds the call's arguments (the event params and the socket), a
  # `KeyError`'s message embeds the map it searched, OTP's crash report prints
  # the server state and its last message (a typed `{:change, tag, value}`),
  # and a `GenServer.call` exit carries the request. The policy is
  # `Mob.Agent.Receipt.summarize_error/3`'s, which builds the summary: keep the
  # exception module and the stack frames by arity, drop every argument, value
  # and message except the messages the framework writes itself. A crash is
  # still routable ("a `KeyError` in `MyScreen.handle_event/3` at line 12"),
  # and the receipt store records which event caused it.
  #
  # `reraise/3` redacts at the source, before the reason becomes the process's
  # exit reason: `format_status/1` cannot, because gen_server appends the raw
  # stacktrace to the reason after calling it.

  import Kernel, except: [reraise: 3]

  defmodule Redacted do
    @moduledoc false
    # Stands in for the raised exception so log formatters still print a
    # banner and a stacktrace.
    defexception [:exception, :message]

    @impl true
    def message(%{exception: exception, message: nil}) do
      "#{inspect(exception)} (message withheld: exception messages can carry assigns)"
    end

    def message(%{exception: exception, message: message}),
      do: "#{inspect(exception)}: #{message}"
  end

  @doc """
  Re-raises a callback's crash with the reason reduced by `reason/1` and the
  stacktrace's arguments replaced by their arity.

  gen_server treats a value thrown from a callback as its return value, and
  exits with `{:bad_return_value, value}` when it is not a valid one. A throw
  that escapes these servers' callbacks comes from app code, which never holds
  the server's state, so it can only be invalid (or, worse, valid and replace
  the state); it becomes that exit directly, with the value reduced by
  `message/1`. `terminate/2` handles throws itself: gen_server ignores them.
  """
  @spec reraise(:error | :exit | :throw, term(), Exception.stacktrace()) :: no_return()
  def reraise(:throw, value, stacktrace),
    do: :erlang.raise(:exit, {:bad_return_value, message(value)}, strip(stacktrace))

  def reraise(:error, error, stacktrace),
    do: :erlang.raise(:error, redact_exception(error, stacktrace), strip(stacktrace))

  def reraise(:exit, reason, stacktrace),
    do: :erlang.raise(:exit, reason(reason), strip(stacktrace))

  @doc """
  `reraise/3` for `init/1`, where a crash ends the process without a
  `terminate/2`, so the process is scrubbed first (see `scrub_process/0`).
  """
  @spec reraise_init(:error | :exit | :throw, term(), Exception.stacktrace()) :: no_return()
  def reraise_init(kind, reason, stacktrace) do
    scrub_process()
    reraise(kind, reason, stacktrace)
  end

  @doc """
  A callback's return value with its stop reason reduced by `reason/1`. A
  returned stop reason becomes the exit reason, what `terminate/2` and every
  monitor receive, as much as a raised one does. `init/1`'s `{:stop, reason}`
  ends the process without a `terminate/2`, so it scrubs the process too.
  """
  @spec result(term()) :: term()
  def result({:stop, reason}) do
    scrub_process()
    {:stop, reason(reason)}
  end

  def result({:stop, reason, state}), do: {:stop, reason(reason), state}
  def result({:stop, reason, reply, state}), do: {:stop, reason(reason), reply, state}
  def result(other), do: other

  @doc """
  Empties the mailbox and erases the process dictionary, except the `$`-keys
  OTP and Elixir keep there, of a process that is about to exit.

  proc_lib's crash report reads both straight from the dying process, without
  `format_status/1`: a queued `{:change, tag, value}` or anything the app put
  in the dictionary would otherwise be printed once SASL reports are on
  (`handle_sasl_reports: true`). Messages still queued at this point are lost
  with the process either way.
  """
  @spec scrub_process() :: :ok
  def scrub_process do
    flush()

    for {key, _value} <- Process.get(), not reserved_key?(key), do: Process.delete(key)
    :ok
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp reserved_key?(key) when is_atom(key), do: String.starts_with?(Atom.to_string(key), "$")
  defp reserved_key?(_key), do: false

  @doc """
  An exit reason as it may be logged: exceptions and raw Erlang errors become
  `{%Redacted{}, stacktrace}` with arities in place of arguments (a bare
  exception, as gen_server hands `format_status/1`, becomes `%Redacted{}`), a
  call exit keeps the callee by arity, and any other term keeps only its atoms
  and atom-tagged tuples, so `:normal`, `{:shutdown, :closed}` and
  `{:error, :no_session}` survive whole.
  """
  @spec reason(term()) :: term()
  def reason(exception) when is_exception(exception), do: redact_exception(exception, [])

  def reason({error, [_ | _] = stacktrace} = reason) do
    if Enum.all?(stacktrace, &frame?/1),
      do: {redact_exception(error, stacktrace), strip(stacktrace)},
      else: keep_atoms(reason)
  end

  def reason({inner, {module, function, args}})
      when is_atom(module) and is_atom(function) and is_list(args),
      do: {reason(inner), {module, function, length(args)}}

  def reason(reason), do: keep_atoms(reason)

  @doc "`reason/1`, rendered for a log line."
  @spec format(term()) :: String.t()
  def format(reason) do
    case reason(reason) do
      {%Redacted{} = exception, stacktrace} -> Exception.format(:error, exception, stacktrace)
      other -> inspect(other)
    end
  end

  @doc """
  A message as it may be logged: its atom tag and the names the screen's own
  source defines (an event's name, a native input's tag), never a payload. A
  toggle's `true` is user data as much as typed text, so atoms in a payload
  position are redacted too: `{:change, :consent, true}` logs as
  `{:change, :consent, :redacted}`.
  """
  @spec message(term()) :: term()
  def message(message) when is_atom(message), do: message

  def message({:event, event, _params}) when is_binary(event) or is_atom(event),
    do: {:event, event, :redacted}

  def message({:mob_event, _address, event, _payload}) when is_atom(event),
    do: {:mob_event, :redacted, event, :redacted}

  def message({:"$gen_cast", request}), do: {:"$gen_cast", message(request)}
  def message({:"$gen_call", _from, request}), do: {:"$gen_call", :redacted, message(request)}

  def message(message) when is_tuple(message) and is_atom(elem(message, 0)) do
    case Mob.Event.NativeInput.kind(message) do
      :none -> tag_only(message)
      _input -> native_input(message)
    end
  end

  def message(_message), do: :redacted

  defp native_input({event, tag}), do: {event, name(tag)}
  defp native_input({event, tag, _payload}), do: {event, name(tag), :redacted}

  defp name(tag) when is_atom(tag), do: tag
  defp name(_tag), do: :redacted

  defp tag_only(message) do
    [tag | rest] = Tuple.to_list(message)
    List.to_tuple([tag | Enum.map(rest, fn _ -> :redacted end)])
  end

  defp keep_atoms(term) when is_atom(term), do: term

  defp keep_atoms(term) when is_tuple(term) and is_atom(elem(term, 0)),
    do: term |> Tuple.to_list() |> Enum.map(&keep_atoms/1) |> List.to_tuple()

  defp keep_atoms(_term), do: :redacted

  @doc """
  `format_status/1` for a server whose state holds a `Mob.Socket` under
  `:socket`. Applies to OTP's crash report and to `:sys.get_status/1`; the
  assigns keep their keys, so a report still says what the screen held.
  """
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, redact_state(state)}
      {:message, message} -> {:message, message(message)}
      {:reason, reason} -> {:reason, reason(reason)}
      # The `:sys` debug log records every message in and out.
      {:log, _log} -> {:log, []}
      {:queue, queue} when is_list(queue) -> {:queue, Enum.map(queue, &message/1)}
      other -> other
    end)
  end

  defp redact_state(%{socket: %Mob.Socket{assigns: assigns, __mob__: mob}} = state) do
    socket = %Mob.Socket{
      assigns: Map.new(assigns, fn {key, _value} -> {key, :redacted} end),
      __mob__: Map.take(mob, [:screen, :platform])
    }

    %{state | socket: socket}
  end

  defp redact_state(state), do: state

  # Idempotent, so a reason redacted at the source survives `reason/1` again.
  defp redact_exception(%Redacted{} = redacted, _stacktrace), do: redacted

  defp redact_exception(error, stacktrace) do
    exception = Exception.normalize(:error, error, stacktrace)
    summary = Mob.Agent.Receipt.summarize_error(:error, exception, stacktrace)
    %Redacted{exception: summary.exception, message: summary.message}
  end

  defp frame?({module, function, arity_or_args, location})
       when is_atom(module) and is_atom(function) and is_list(location),
       do: is_integer(arity_or_args) or is_list(arity_or_args)

  defp frame?({fun, arity_or_args, location}) when is_function(fun) and is_list(location),
    do: is_integer(arity_or_args) or is_list(arity_or_args)

  defp frame?(_frame), do: false

  # `error_info` and anything else a location may grow can carry values; the
  # file and line are what locate the frame.
  defp strip(stacktrace), do: Enum.map(stacktrace, &strip_frame/1)

  defp strip_frame({module, function, arity_or_args, location}),
    do: {module, function, arity(arity_or_args), Keyword.take(location, [:file, :line])}

  defp strip_frame({fun, arity_or_args, location}),
    do: {fun, arity(arity_or_args), Keyword.take(location, [:file, :line])}

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity), do: arity
end
