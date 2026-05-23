defmodule MobIap.SubscriptionScreen do
  @moduledoc """
  Active subscriptions management screen.

  Shows current subscriptions with expiry dates and provides access to the
  OS-level subscription management UI.

  Routes to this screen via `Mob.Nav.push(socket, MobIap.SubscriptionScreen)`.
  """

  use Mob.Screen

  def mount(_params, _session, socket) do
    socket =
      socket
      |> Mob.Socket.assign(:entitlements, [])
      |> Mob.Socket.assign(:loading, true)
      |> Mob.Socket.assign(:error, nil)

    MobIap.current_entitlements(socket)
    {:ok, socket}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={:space_md} bg={:background}>
      <Text text="Subscriptions" text_size={:xl} text_weight={:bold} />

      <Box spacer={:space_md} />

      {render_content(assigns)}

      <Box spacer={:space_lg} />

      {render_manage_button()}
    </Column>
    """
  end

  defp render_content(%{loading: true}) do
    ~MOB(<Text text="Loading subscriptions…" text_color={:muted} />)
  end

  defp render_content(%{error: err}) when not is_nil(err) do
    ~MOB(<Text text="Could not load subscriptions" text_color={:red} />)
  end

  defp render_content(%{entitlements: []}) do
    ~MOB"""
    <Column align={:center}>
      <Box spacer={:space_xl} />
      <Text text="No active subscriptions" text_color={:muted} text_size={:lg} />
      <Box spacer={:space_sm} />
      <Text text="Visit the Store to subscribe" text_color={:muted} text_size={:sm} />
    </Column>
    """
  end

  defp render_content(%{entitlements: entitlements}) do
    ~MOB"""
    <List>
      {Enum.map(entitlements, fn tx ->
        entitlement_node(tx)
      end)}
    </List>
    """
  end

  defp entitlement_node(tx) do
    expires_text =
      if tx.expires_date do
        date = DateTime.from_unix!(div(tx.expires_date, 1000))
        "Renews #{Calendar.strftime(date, "%B %d, %Y")}"
      else
        "Lifetime"
      end

    ~MOB"""
    <Box
      padding={:space_md}
      bg={:card_bg}
      radius={:radius_md}
      margin={%{bottom: 12}}
    >
      <Column>
        <Row align={:between} align_y={:center}>
          <Text text={tx.product_id} text_weight={:semibold} />
          <Text text={if tx.environment == :sandbox, do: "SANDBOX", else: ""}
                text_color={:orange} text_size={:xs} />
        </Row>

        <Box spacer={4} />

        <Text text={expires_text} text_color={:muted} text_size={:sm} />
      </Column>
    </Box>
    """
  end

  defp render_manage_button() do
    tap = {self(), :manage}

    ~MOB"""
    <Button
      text="Manage Subscriptions"
      on_tap={tap}
      align={:center}
    />
    """
  end

  # ── Event handling ────────────────────────────────────────────────────

  def handle_event(:manage, _params, socket) do
    MobIap.manage_subscriptions(socket)
    {:noreply, socket}
  end

  # ── IAP messages ──────────────────────────────────────────────────────

  def handle_info({:iap, :entitlements, json}, socket) do
    entitlements =
      json
      |> MobIap.decode_transactions!()
      |> Enum.filter(fn tx ->
        tx.expires_date == nil or tx.expires_date > System.os_time(:millisecond)
      end)

    {:noreply,
     socket
     |> Mob.Socket.assign(:entitlements, entitlements)
     |> Mob.Socket.assign(:loading, false)}
  end

  def handle_info({:iap, :entitlements_failed}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:loading, false)
     |> Mob.Socket.assign(:error, "Failed to load subscriptions")}
  end
end
