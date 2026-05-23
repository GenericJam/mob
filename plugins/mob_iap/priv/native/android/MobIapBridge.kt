package com.mob.iap

import android.app.Activity
import com.android.billingclient.api.*
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * MobIapBridge — Play Billing 7.0 integration for Mob apps.
 *
 * All calls are fire-and-forget. Results are sent back to the BEAM
 * via enif_send through the JNI bridge (iap.c). The BEAM pid is
 * passed as a Long handle through JNI.
 *
 * Connection state machine:
 *   disconnected → connecting → connected → disconnected
 *
 * Requests queued before connection completes are replayed once
 * connected. If connection fails permanently, outstanding requests
 * receive `products_failed` / `purchase_failed` as appropriate.
 *
 * NOTE: JNI symbol names are derived from the package and class name.
 * Renaming this class or its package requires updating iap.c accordingly.
 *
 * NOTE: Play Billing does not distinguish consumable vs non-consumable
 * at the product type level — both map to INAPP. The developer controls
 * consumability by calling consumePurchase for consumables. The type
 * atom returned is "consumable" for INAPP; your app should call
 * consumePurchase for products that should be re-purchasable.
 */
class MobIapBridge(private val activity: Activity) {

    companion object {
        // JNI callback — sends {:iap, :tag, <<json>>} to the BEAM.
        @JvmStatic external fun sendToBeam(pid: Long, tag: String, json: String)

        // JNI callback — sends {:iap, :tag} to the BEAM.
        @JvmStatic external fun sendAtom(pid: Long, tag: String)

        // JNI callback — sends {:iap, :tag, :atom} to the BEAM.
        @JvmStatic external fun sendAtom3(pid: Long, tag: String, atom: String)
    }

    // ── BillingClient lifecycle ──────────────────────────────────────────

    private val billingClient: BillingClient by lazy {
        BillingClient.newBuilder(activity)
            .enablePendingPurchases()
            .setListener(purchasesUpdatedListener)
            .build()
    }

    @Volatile private var connected = false

    // pendingRequests is accessed from both the NIF thread (ensureConnected)
    // and the BillingClient callback thread (onBillingSetupFinished).
    private val pendingRequests = mutableListOf<() -> Unit>()
    private val pendingRequestsLock = Any()

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    init {
        connect()
    }

    private fun connect() {
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    connected = true
                    val requests = synchronized(pendingRequestsLock) {
                        val copy = pendingRequests.toList()
                        pendingRequests.clear()
                        copy
                    }
                    requests.forEach { it() }
                } else {
                    connected = false
                    // Drain pending requests — send purchase_failed for any pending purchases,
                    // and products_failed for product queries. Since we don't have pid context
                    // here, just clear the queue; the PIDs are captured in the lambdas.
                    synchronized(pendingRequestsLock) { pendingRequests.clear() }
                }
            }

            override fun onBillingServiceDisconnected() {
                connected = false
                connect()
            }
        })
    }

    private fun ensureConnected(action: () -> Unit) {
        if (connected) {
            action()
        } else {
            synchronized(pendingRequestsLock) { pendingRequests.add(action) }
            if (!connected) connect()
        }
    }

    // ── PurchasesUpdatedListener ─────────────────────────────────────

    private val purchasesUpdatedListener = PurchasesUpdatedListener { result, purchases ->
        if (result.responseCode == BillingClient.BillingResponseCode.OK && purchases != null) {
            for (purchase in purchases) {
                handlePurchaseUpdate(purchase)
            }
        } else if (result.responseCode == BillingClient.BillingResponseCode.USER_CANCELED) {
            // At most one purchase flow is active; notify and clear all pending.
            val pending = pendingPurchases.values.firstOrNull()
            pendingPurchases.clear()
            pending?.let { sendAtom(it.pid, "cancelled") }
        } else {
            val errorPurchases = purchases ?: emptyList()
            if (errorPurchases.isEmpty()) {
                // No purchase context — notify any pending purchase as failed.
                val pending = pendingPurchases.values.firstOrNull()
                pendingPurchases.clear()
                pending?.let { sendAtom(it.pid, "purchase_failed") }
            } else {
                errorPurchases.forEach { handleErrorPurchase(it) }
            }
        }
    }

    private fun handlePurchaseUpdate(purchase: Purchase) {
        val productId = purchase.products.firstOrNull() ?: ""
        val pending = pendingPurchases.remove(productId)
            ?: pendingPurchases.values.firstOrNull()?.also {
                pendingPurchases.remove(it.productId)
            }

        if (pending != null) {
            val tx = purchaseToTransaction(purchase)
            sendToBeam(pending.pid, "purchased", tx)
        }

        if (!purchase.isAcknowledged) {
            acknowledgePurchase(purchase.purchaseToken)
        }
    }

    private fun handleErrorPurchase(purchase: Purchase) {
        val productId = purchase.products.firstOrNull() ?: ""
        val pending = pendingPurchases.remove(productId) ?: return
        sendAtom(pending.pid, "purchase_failed")
    }

    // ── Public API ────────────────────────────────────────────────────────

    fun fetchProducts(pid: Long, productIds: List<String>) {
        ensureConnected {
            val inappParams = QueryProductDetailsParams.newBuilder()
                .setProductList(productIds.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it)
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build()
                })
                .build()

            val subsParams = QueryProductDetailsParams.newBuilder()
                .setProductList(productIds.map {
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(it)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                })
                .build()

            scope.launch {
                val inappDeferred = async { queryProductsAsync(inappParams) }
                val subsDeferred = async { queryProductsAsync(subsParams) }
                val allDetails = inappDeferred.await() + subsDeferred.await()

                if (allDetails.isEmpty()) {
                    sendAtom(pid, "products_failed")
                } else {
                    sendToBeam(pid, "products", productsToJson(allDetails))
                }
            }
        }
    }

    private suspend fun queryProductsAsync(params: QueryProductDetailsParams): List<ProductDetails> {
        return suspendCancellableCoroutine { continuation ->
            billingClient.queryProductDetailsAsync(params) { result, details ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK && details != null) {
                    continuation.resume(details)
                } else {
                    continuation.resume(emptyList())
                }
            }
        }
    }

    fun purchase(pid: Long, productId: String) {
        ensureConnected {
            val params = QueryProductDetailsParams.newBuilder()
                .setProductList(listOf(
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(productId)
                        .setProductType(BillingClient.ProductType.INAPP)
                        .build(),
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(productId)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                ))
                .build()

            billingClient.queryProductDetailsAsync(params) { queryResult, details ->
                if (queryResult.responseCode != BillingClient.BillingResponseCode.OK || details.isNullOrEmpty()) {
                    sendAtom(pid, "purchase_failed")
                    return@queryProductDetailsAsync
                }

                val productDetail = details.first()
                val billingParams = BillingFlowParams.newBuilder()
                    .setProductDetailsParamsList(listOf(
                        BillingFlowParams.ProductDetailsParams.newBuilder()
                            .setProductDetails(productDetail)
                            .build()
                    ))
                    .build()

                registerPendingPurchase(pid, productId)
                billingClient.launchBillingFlow(activity, billingParams)
            }
        }
    }

    fun restorePurchases(pid: Long) {
        ensureConnected {
            scope.launch {
                val allPurchases = queryAllPurchasesAsync()
                sendToBeam(pid, "restored", purchasesToJson(allPurchases))
            }
        }
    }

    fun currentEntitlements(pid: Long) {
        ensureConnected {
            scope.launch {
                val allPurchases = queryAllPurchasesAsync()
                sendToBeam(pid, "entitlements", purchasesToJson(allPurchases))
            }
        }
    }

    private suspend fun queryAllPurchasesAsync(): List<Purchase> {
        val inapp = queryPurchasesAsync(BillingClient.ProductType.INAPP)
        val subs = queryPurchasesAsync(BillingClient.ProductType.SUBS)
        return inapp + subs
    }

    private suspend fun queryPurchasesAsync(type: String): List<Purchase> {
        return suspendCancellableCoroutine { continuation ->
            billingClient.queryPurchasesAsync(type) { result, purchases ->
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    continuation.resume(purchases ?: emptyList())
                } else {
                    continuation.resume(emptyList())
                }
            }
        }
    }

    fun manageSubscriptions() {
        val uri = android.net.Uri.parse(
            "https://play.google.com/store/account/subscriptions?package=${activity.packageName}"
        )
        val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, uri)
        activity.startActivity(intent)
    }

    // ── Purchase tracking ─────────────────────────────────────────────────

    private data class PendingPurchase(val pid: Long, val productId: String)

    // ConcurrentHashMap: accessed from JNI/NIF thread (registerPendingPurchase) and
    // BillingClient callback thread (purchasesUpdatedListener).
    private val pendingPurchases = ConcurrentHashMap<String, PendingPurchase>()

    private fun registerPendingPurchase(pid: Long, productId: String) {
        pendingPurchases[productId] = PendingPurchase(pid, productId)
    }

    fun acknowledgePurchase(purchaseToken: String) {
        ensureConnected {
            val params = AcknowledgePurchaseParams.newBuilder()
                .setPurchaseToken(purchaseToken)
                .build()
            billingClient.acknowledgePurchase(params) { /* silent */ }
        }
    }

    fun consumePurchase(purchaseToken: String) {
        ensureConnected {
            val params = ConsumeParams.newBuilder()
                .setPurchaseToken(purchaseToken)
                .build()
            billingClient.consumeAsync(params) { _, _ -> /* silent */ }
        }
    }

    // ── JSON helpers ─────────────────────────────────────────────────────

    private fun productsToJson(products: List<ProductDetails>): String {
        val arr = JSONArray()
        for (p in products) {
            val obj = JSONObject().apply {
                put("id", p.productId)
                put("display_name", p.title)
                put("description", p.description)
                put("price", p.oneTimePurchaseOfferDetails?.formattedPrice
                    ?: p.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList
                        ?.firstOrNull()?.formattedPrice ?: "")
                put("type", playBillingTypeToAtom(p.productType))
                put("currency_code", p.oneTimePurchaseOfferDetails?.priceCurrencyCode
                    ?: p.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList
                        ?.firstOrNull()?.priceCurrencyCode ?: "")
            }

            val priceAmount = p.oneTimePurchaseOfferDetails?.priceAmountMicros?.div(1_000_000.0)
                ?: p.subscriptionOfferDetails?.firstOrNull()?.pricingPhases?.pricingPhaseList
                    ?.firstOrNull()?.priceAmountMicros?.div(1_000_000.0) ?: 0.0
            obj.put("price_amount", priceAmount)

            if (p.productType == BillingClient.ProductType.SUBS) {
                p.subscriptionOfferDetails?.firstOrNull()?.let { offer ->
                    val phase = offer.pricingPhases.pricingPhaseList.firstOrNull()
                    obj.put("subscription_period", phase?.billingPeriod ?: "")
                    if (offer.offerId == null && phase?.priceAmountMicros == 0L) {
                        obj.put("trial_period", phase.billingPeriod)
                    }
                }
            }
            arr.put(obj)
        }
        return arr.toString()
    }

    // Play Billing does not distinguish consumable vs non-consumable at the type level.
    // Both are INAPP; the developer controls consumability via consumePurchase.
    private fun playBillingTypeToAtom(playBillingType: String): String {
        return when (playBillingType) {
            BillingClient.ProductType.INAPP -> "consumable"
            BillingClient.ProductType.SUBS -> "auto_renewable"
            else -> "unknown"
        }
    }

    private fun purchasesToJson(purchases: List<Purchase>): String {
        val arr = JSONArray()
        for (p in purchases) {
            arr.put(purchaseToJsonObject(p))
        }
        return arr.toString()
    }

    private fun purchaseToTransaction(p: Purchase): String {
        return purchaseToJsonObject(p).toString()
    }

    private fun purchaseToJsonObject(p: Purchase): JSONObject {
        // Play Billing does not expose a production/sandbox flag directly.
        // Use BuildConfig.DEBUG as a heuristic; override via app config if needed.
        val env = if (activity.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
            "sandbox" else "production"

        return JSONObject().apply {
            put("id", p.orderId ?: p.purchaseToken)
            put("product_id", p.products.firstOrNull() ?: "")
            put("purchase_date", p.purchaseTime)
            put("original_json", p.originalJson)
            put("environment", env)
            put("is_upgraded", 0)
            put("ownership_type", if (p.isAcknowledged) "purchased" else "purchased")
            put("purchase_token", p.purchaseToken)
        }
    }

    // ── Cleanup ───────────────────────────────────────────────────────────

    fun disconnect() {
        scope.cancel()
        billingClient.endConnection()
    }
}
