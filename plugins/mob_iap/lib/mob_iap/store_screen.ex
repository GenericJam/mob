defmodule MobIap.StoreScreen do
  @moduledoc """
  Product storefront screen.

  Displays a scrollable list of products fetched from the app store with
  localized pricing. Handles the full purchase flow — tap → native dialog → result.

  Routes to this screen via `Mob.Socket.push_screen(socket, MobIap.StoreScreen)`.

  ## Props

    - `product_ids` — list of atom product ids to display (default: all configured)
    - `title` — screen title (default: "Store")
  """

  use Mob.Screen

  def mount(params, _session, socket) do
    product_ids = params[:product_ids] || []
    title = params[:title] || "Store"

    socket =
      socket
      |> Mob.Socket.assign(:product_ids, product_ids)
      |> Mob.Socket.assign(:title, title)
      |> Mob.Socket.assign(:products, [])
      |> Mob.Socket.assign(:state, :loading)
      |> Mob.Socket.assign(:error, nil)
      |> Mob.Socket.assign(:purchasing_id, nil)

    # Fetch products on mount
    if product_ids != [], do: MobIap.fetch_products(socket, product_ids)

    {:ok, socket}
  end

  def render(assigns) do
    ~MOB"""
    <Column padding={:space_md} bg={:background}>
      <Text text={assigns.title} text_size={:xl} text_weight={:bold} />

      {render_content(assigns)}

      <Box spacer={:space_lg} />

      {render_restore(assigns)}
    </Column>
    """
  end

  defp render_content(%{state: :loading} = _assigns) do
    ~MOB(<Text text="Loading products…" text_color={:muted} />)
  end

  defp render_content(%{state: :error, error: error}) do
    ~MOB"""
    <Column>
      <Text text="Failed to load products" text_color={:red} />
      <Text text={error} text_color={:muted} text_size={:sm} />
    </Column>
    """
  end

  defp render_content(%{state: :products, products: products, purchasing_id: purchasing_id}) do
    ~MOB"""
    <List>
      {Enum.map(products, fn product ->
        is_purchasing = product.id == purchasing_id
        product_node(product, is_purchasing)
      end)}
    </List>
    """
  end

  defp render_content(assigns) do
    render_content(%{assigns | state: :products})
  end

  defp product_node(product, is_purchasing) do
    tap = {self(), {:purchase, product.id}}

    ~MOB"""
    <Box
      padding={:space_md}
      bg={:card_bg}
      radius={:radius_md}
      margin={%{bottom: 12}}
    >
      <Column>
        <Row align={:between} align_y={:center}>
          <Text text={product.display_name} text_weight={:semibold} />
          <Text text={product.price} text_weight={:bold} text_color={:primary} />
        </Row>

        <Box spacer={4} />

        <Text text={product.description} text_color={:muted} text_size={:sm} />

        <Box spacer={8} />

        {if product.trial_period do
          ~MOB(<Text text={"Free trial: #{product.trial_period}"} text_color={:green} text_size={:sm} />)
        end}

        {if product.introductory_offer do
          ~MOB(<Text text={"Intro offer: #{product.introductory_offer["price"]} for #{product.introductory_offer["period"]}"} text_color={:green} text_size={:sm} />)
        end}

        <Box spacer={8} />

        <Button
          text={if is_purchasing, do: "Purchasing…", else: button_label(product.type)}
          on_tap={tap}
          disabled={is_purchasing}
        />
      </Column>
    </Box>
    """
  end

  defp button_label(:auto_renewable), do: "Subscribe"
  defp button_label(:non_renewing), do: "Subscribe"
  defp button_label(:consumable), do: "Buy"
  defp button_label(:non_consumable), do: "Buy"

  defp render_restore(%{state: :loading}) do
    ~MOB(<Box />)
  end

  defp render_restore(_assigns) do
    tap = {self(), :restore}

    ~MOB"""
    <Button
      text="Restore Purchases"
      on_tap={tap}
      variant={:outline}
      align={:center}
    />
    """
  end

  # ── Event handling ────────────────────────────────────────────────────

  def handle_event({:purchase, product_id}, _params, socket) when is_binary(product_id) do
    socket = Mob.Socket.assign(socket, :purchasing_id, product_id)
    MobIap.purchase(socket, String.to_atom(product_id))
    {:noreply, socket}
  end

  def handle_event(:restore, _params, socket) do
    MobIap.restore(socket)
    {:noreply, socket}
  end

  # ── IAP messages ──────────────────────────────────────────────────────

  def handle_info({:iap, :products, json}, socket) do
    products = MobIap.decode_products!(json)

    {:noreply,
     socket
     |> Mob.Socket.assign(:products, products)
     |> Mob.Socket.assign(:state, :products)}
  end

  def handle_info({:iap, :products_failed}, socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:state, :error)
     |> Mob.Socket.assign(:error, "Store unavailable")}
  end

  def handle_info({:iap, :purchased, json}, socket) do
    tx = MobIap.decode_transaction!(json)

    {:noreply,
     socket
     |> Mob.Socket.assign(:purchasing_id, nil)
     |> Mob.Socket.assign(:last_transaction, tx)}
  end

  def handle_info({:iap, :cancelled}, socket) do
    {:noreply, Mob.Socket.assign(socket, :purchasing_id, nil)}
  end

  def handle_info({:iap, :purchase_failed}, socket) do
    {:noreply, Mob.Socket.assign(socket, :purchasing_id, nil)}
  end

  def handle_info({:iap, :purchase_pending, json}, socket) do
    tx = MobIap.decode_transaction!(json)

    {:noreply,
     socket
     |> Mob.Socket.assign(:purchasing_id, nil)
     |> Mob.Socket.assign(:pending_transaction, tx)}
  end

  def handle_info({:iap, :restored, json}, socket) do
    transactions = MobIap.decode_transactions!(json)
    {:noreply, Mob.Socket.assign(socket, :restored_transactions, transactions)}
  end
end
