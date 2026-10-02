defmodule Mob.SizeClass do
  @moduledoc """
  The window's size class, `{horizontal, vertical}`, each `:compact` or
  `:regular`.

  Every screen socket carries it as `assigns.size_class`. The framework sets it
  before `mount/3` and keeps it current; a screen never asks for it.

  Size classes are the layout signal, not orientation or raw dimensions. An
  iPad in Split View is a phone-shaped window on a tablet; a foldable flips
  class when it opens. Typical values:

  | Window                                    | Size class              |
  |-------------------------------------------|-------------------------|
  | iPhone, portrait                          | `{:compact, :regular}`  |
  | Large iPhone (Plus, Pro Max, XR/11-class, 414pt wide or more), landscape | `{:regular, :compact}` |
  | Smaller iPhones, landscape                | `{:compact, :compact}`  |
  | iPad full screen, either orientation      | `{:regular, :regular}`  |
  | iPad Slide Over, narrow Split View        | `{:compact, :regular}`  |
  | Android phone, portrait                   | `{:compact, :regular}`  |
  | Android phone, landscape                  | `{:regular, :compact}`  |
  | Android tablet / unfolded foldable        | `{:regular, :regular}`  |

  ## Where the value comes from

    * **iOS** — the window's `traitCollection.horizontalSizeClass` and
      `.verticalSizeClass`, exactly as UIKit reports them.
    * **Android** — Android has no OS size class, so it is derived from the
      activity's `Configuration.screenWidthDp` / `screenHeightDp` with the
      Material window-size-class breakpoints: horizontal is `:compact` below
      600dp wide, vertical is `:compact` below 480dp tall; Material's
      "medium" and "expanded" both map to `:regular`. These are the numbers
      Android's own `w600dp` / `h480dp` resource qualifiers select on. See
      `decisions/2026-10-01-size-class-in-socket-assigns.md` for why this and
      not Compose's `WindowSizeClass`.

  ## Changes

  When the window's class changes — rotation, an iPad Split View / Slide Over /
  Stage Manager resize, an Android multi-window resize, a foldable opening —
  every live screen gets the new value in `assigns.size_class` and then
  `handle_info({:mob_size_class_changed, new}, socket)`. By the time that
  callback runs the assign already holds `new`; a screen that only reads
  `assigns.size_class` in `render/1` needs no clause at all, and one without a
  matching clause is not crashed by it.

  ## Before the platform can answer

  On iOS the BEAM can start before a window exists (a prewarmed or background
  launch). Screens mounted then hold `placeholder/0`; the root view reports the
  real value as soon as it appears, which arrives as an ordinary change.
  `Mob.ScreenCase.mount_screen/4` uses the same placeholder unless told
  otherwise.
  """

  @typedoc "One axis of a size class."
  @type class :: :compact | :regular

  @typedoc "`{horizontal, vertical}`."
  @type t :: {class(), class()}

  @placeholder {:compact, :regular}

  @doc """
  The value a screen holds when the platform cannot answer yet, and the
  default under `Mob.ScreenCase`: `{:compact, :regular}`, a portrait phone.
  """
  @spec placeholder() :: t()
  def placeholder, do: @placeholder

  @doc false
  defguard class?(c) when c in [:compact, :regular]

  @doc "True for a well-formed size class."
  @spec valid?(term()) :: boolean()
  def valid?({h, v}) when class?(h) and class?(v), do: true
  def valid?(_other), do: false

  @doc false
  # Ask the platform, through `nif` (`:mob_nif` on device, a stub in tests).
  #
  # Anything other than a size class is "no answer yet", never a crash on the
  # mount path: `:no_window` from iOS before a window exists, or from Android
  # before an activity is attached or without a JNI env; and an exception when
  # the loaded native library predates `size_class/0` — a hot-pushed mob on an
  # app whose native layer was not rebuilt — or when a test stub does not
  # define it.
  @spec read(module()) :: t()
  def read(nif) do
    case nif.size_class() do
      {h, v} = size_class when class?(h) and class?(v) -> size_class
      _no_answer -> @placeholder
    end
  catch
    :error, reason when reason in [:undef, :not_loaded] -> @placeholder
  end

  @doc false
  # Give `screen`'s socket the window's new size class: write the assign, then
  # call `handle_info({:mob_size_class_changed, new}, socket)`. `:unchanged`
  # when the socket already holds `new` — native reports on every trait or
  # configuration pass, not only on a change, and a repeat must cost neither a
  # callback nor a paint.
  @spec apply_change(module(), Mob.Socket.t(), t()) :: {:noreply, Mob.Socket.t()} | :unchanged
  def apply_change(screen, socket, new) do
    if socket.assigns[:size_class] == new, do: :unchanged, else: deliver(screen, socket, new)
  end

  @doc false
  # `apply_change/3` without the "already holds it" check, for when the
  # socket's current value says nothing about the window its other assigns
  # were derived in: a persisted dump that did not record a size class (a
  # custom `dump_state/1`, or a dump written before MOB-204).
  #
  # The framework sends this unprompted, to every live screen, on every
  # rotation. `use Mob.Screen` injects a catch-all handle_info, but a screen
  # that overrides handle_info/2 without one has no clause for it, and dying
  # would cost every such screen its state each time the device turned. So "no
  # clause for this message" is not a crash: the socket keeps the new assign.
  # Only a head mismatch on exactly this message counts — the top frame is the
  # screen's own handle_info/2 called with it. Anything raised from inside a
  # clause's body still propagates.
  @spec deliver(module(), Mob.Socket.t(), t()) :: {:noreply, Mob.Socket.t()}
  def deliver(screen, socket, new) do
    socket = Mob.Socket.assign(socket, :size_class, new)
    message = {:mob_size_class_changed, new}

    try do
      screen.handle_info(message, socket)
    catch
      :error, :function_clause ->
        case __STACKTRACE__ do
          [{^screen, :handle_info, [^message, _socket], _location} | _] ->
            {:noreply, socket}

          stacktrace ->
            :erlang.raise(:error, :function_clause, stacktrace)
        end
    end
  end
end
