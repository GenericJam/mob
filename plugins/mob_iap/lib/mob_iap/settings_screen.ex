defmodule MobIap.SettingsScreen do
  @moduledoc """
  Plugin settings editor for mob_iap.

  Allows toggling receipt auto-verification and configuring the server-side
  verification endpoint.
  """

  use Mob.Screen

  def mount(_params, _session, socket) do
    socket =
      socket
      |> Mob.Socket.assign(
        :auto_verify,
        Application.get_env(:mob_iap, :auto_verify_receipts, true)
      )
      |> Mob.Socket.assign(
        :verification_endpoint,
        Application.get_env(:mob_iap, :verification_endpoint, "")
      )
      |> Mob.Socket.assign(:saved, false)

    {:ok, socket}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={:space_md} bg={:background}>
      <Text text="IAP Settings" text_size={:xl} text_weight={:bold} />

      <Box spacer={:space_md} />

      {render_auto_verify_toggle(assigns)}

      <Box spacer={:space_md} />

      {render_endpoint_field(assigns)}

      <Box spacer={:space_lg} />

      {render_save_button(assigns)}

      {if assigns.saved do
        ~MOB(<Text text="Settings saved" text_color={:green} text_size={:sm} align={:center} />)
      end}
    </Column>
    """
  end

  defp render_auto_verify_toggle(assigns) do
    tap = {self(), :toggle_auto_verify}

    ~MOB"""
    <Row align={:between} align_y={:center} padding={%{vertical: 8}}>
      <Column flex={1}>
        <Text text="Auto-verify receipts" text_weight={:semibold} />
        <Text text="Verify purchases with your server automatically"
              text_color={:muted} text_size={:sm} />
      </Column>
      <Button
        text={if assigns.auto_verify, do: "ON", else: "OFF"}
        on_tap={tap}
        variant={if assigns.auto_verify, do: :primary, else: :outline}
      />
    </Row>
    """
  end

  defp render_endpoint_field(assigns) do
    change = {self(), :endpoint_changed}

    ~MOB"""
    <Column>
      <Text text="Verification Endpoint" text_weight={:semibold} />
      <Box spacer={4} />
      <TextField
        value={assigns.verification_endpoint}
        placeholder="https://api.example.com/verify-receipt"
        on_change={change}
        keyboard={:url}
        autocorrect={false}
        autocapitalize={:none}
      />
    </Column>
    """
  end

  defp render_save_button(_assigns) do
    tap = {self(), :save}

    ~MOB"""
    <Button text="Save Settings" on_tap={tap} variant={:primary} align={:center} />
    """
  end

  # ── Event handling ────────────────────────────────────────────────────

  def handle_event(:toggle_auto_verify, _params, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:auto_verify, not socket.assigns.auto_verify)
     |> Mob.Socket.assign(:saved, false)}
  end

  def handle_event(:endpoint_changed, %{value: value}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:verification_endpoint, value)
     |> Mob.Socket.assign(:saved, false)}
  end

  def handle_event(:save, _params, socket) do
    Application.put_env(:mob_iap, :auto_verify_receipts, socket.assigns.auto_verify)
    Application.put_env(:mob_iap, :verification_endpoint, socket.assigns.verification_endpoint)
    {:noreply, Mob.Socket.assign(socket, :saved, true)}
  end
end
