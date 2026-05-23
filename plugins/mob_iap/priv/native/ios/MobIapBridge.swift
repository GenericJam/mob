import StoreKit

// ── Bridging helpers (implemented in mob_nif.m) ──────────────────────────
// These are declared here for Swift access; implementations live in C.
@_silgen_name("mob_iap_send2")
func mob_iap_send2(_ pidBytes: UnsafeRawPointer, _ tag: UnsafePointer<CChar>, _ atom: UnsafePointer<CChar>)

@_silgen_name("mob_iap_send3")
func mob_iap_send3(_ pidBytes: UnsafeRawPointer, _ tag: UnsafePointer<CChar>, _ a1: UnsafePointer<CChar>, _ a2: UnsafePointer<CChar>)

@_silgen_name("mob_iap_send_products")
func mob_iap_send_products(_ pidBytes: UnsafeRawPointer, _ json: UnsafePointer<CChar>)

@_silgen_name("mob_iap_send_transaction")
func mob_iap_send_transaction(_ pidBytes: UnsafeRawPointer, _ tag: UnsafePointer<CChar>, _ json: UnsafePointer<CChar>)

@_silgen_name("mob_iap_send_transactions")
func mob_iap_send_transactions(_ pidBytes: UnsafeRawPointer, _ tag: UnsafePointer<CChar>, _ json: UnsafePointer<CChar>)

// ═══════════════════════════════════════════════════════════════════════════
// MobIapBridge — StoreKit 2 integration
// ═══════════════════════════════════════════════════════════════════════════

@objc public class MobIapBridge: NSObject {

    // MARK: - Fetch products

    /// Fetch products from the App Store. Results sent as `{:iap, :products, json}`.
    @objc public static func fetchProducts(_ productIds: [String], pidBytes: UnsafeRawPointer) {
        Task {
            do {
                let products = try await Product.products(for: Set(productIds))
                let productMaps = products.map { productToMap($0) }
                let data = try JSONSerialization.data(withJSONObject: productMaps)
                let json = String(data: data, encoding: .utf8)!
                json.withCString { mob_iap_send_products(pidBytes, $0) }
            } catch {
                "iap".withCString { tag in
                    "products_failed".withCString { atom in
                        mob_iap_send2(pidBytes, tag, atom)
                    }
                }
            }
        }
    }

    // MARK: - Purchase

    /// Purchase a product. Results sent as `{:iap, :purchased, json}`, `{:iap, :cancelled}`, etc.
    @objc public static func purchase(_ productId: String, pidBytes: UnsafeRawPointer) {
        Task {
            guard let product = try? await Product.products(for: [productId]).first else {
                "iap".withCString { t in
                    "purchase_failed".withCString { a in
                        mob_iap_send2(pidBytes, t, a)
                    }
                }
                return
            }

            do {
                let result = try await product.purchase()

                switch result {
                case .success(let verification):
                    switch verification {
                    case .verified(let transaction):
                        let txMap = transactionToMap(transaction)
                        let data = try JSONSerialization.data(withJSONObject: txMap)
                        let json = String(data: data, encoding: .utf8)!
                        json.withCString { mob_iap_send_transaction(pidBytes, "purchased", $0) }
                        await transaction.finish()

                    case .unverified(_, _):
                        "iap".withCString { t in
                            "purchase_failed".withCString { a in
                                mob_iap_send2(pidBytes, t, a)
                            }
                        }
                    }

                case .userCancelled:
                    "iap".withCString { t in
                        "cancelled".withCString { a in
                            mob_iap_send2(pidBytes, t, a)
                        }
                    }

                case .pending:
                    "iap".withCString { t in
                        "purchase_pending".withCString { a in
                            mob_iap_send2(pidBytes, t, a)
                        }
                    }

                @unknown default:
                    "iap".withCString { t in
                        "purchase_failed".withCString { a in
                            mob_iap_send2(pidBytes, t, a)
                        }
                    }
                }
            } catch {
                "iap".withCString { t in
                    "purchase_failed".withCString { a in
                        mob_iap_send2(pidBytes, t, a)
                    }
                }
            }
        }
    }

    // MARK: - Restore

    /// Restore previous purchases via `AppStore.sync()`. Results as `{:iap, :restored, json}`.
    @objc public static func restorePurchases(_ pidBytes: UnsafeRawPointer) {
        Task {
            do {
                // StoreKit 2: AppStore.sync() re-syncs the transaction history with the App Store.
                try await AppStore.sync()

                var txMaps: [[String: Any]] = []
                for await verification in Transaction.all {
                    if case .verified(let tx) = verification {
                        txMaps.append(transactionToMap(tx))
                        await tx.finish()
                    }
                }

                let data = try JSONSerialization.data(withJSONObject: txMaps)
                let json = String(data: data, encoding: .utf8)!
                json.withCString { mob_iap_send_transactions(pidBytes, "restored", $0) }
            } catch {
                "iap".withCString { t in
                    "restore_failed".withCString { a in
                        mob_iap_send2(pidBytes, t, a)
                    }
                }
            }
        }
    }

    // MARK: - Current entitlements

    /// Fetch current entitlements (active subscriptions + non-consumables).
    /// Results as `{:iap, :entitlements, json}`.
    @objc public static func currentEntitlements(_ pidBytes: UnsafeRawPointer) {
        Task {
            var txMaps: [[String: Any]] = []
            for await verification in Transaction.currentEntitlements {
                if case .verified(let tx) = verification {
                    txMaps.append(transactionToMap(tx))
                    await tx.finish()
                }
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: txMaps)
                let json = String(data: data, encoding: .utf8)!
                json.withCString { mob_iap_send_transactions(pidBytes, "entitlements", $0) }
            } catch {
                "iap".withCString { t in
                    "entitlements_failed".withCString { a in
                        mob_iap_send2(pidBytes, t, a)
                    }
                }
            }
        }
    }

    // MARK: - Manage subscriptions

    /// Open the OS-level subscription management UI.
    @objc public static func manageSubscriptions() {
        Task {
            // StoreKit 2: opens the system subscription management sheet.
            // Available iOS 15+. Requires the app to be in the foreground.
            if let windowScene = await UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                do {
                    try await AppStore.showManageSubscriptions(in: windowScene)
                } catch {
                    // Fallback: open the App Store subscriptions page
                    if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                        await UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Marshal a StoreKit Product to a JSON-compatible dictionary matching the
    /// `MobIap.Product` struct fields on the Elixir side.
    private static func productToMap(_ product: Product) -> [String: Any] {
        var map: [String: Any] = [
            "id": product.id,
            "display_name": product.displayName,
            "description": product.description,
            "price": product.displayPrice,
            "price_amount": Double(truncating: product.price as NSNumber),
            "currency_code": product.priceFormatStyle.locale.identifier,
            "type": productTypeToString(product.type),
        ]

        if let sub = product.subscription {
            let period = sub.subscriptionPeriod
            map["subscription_period"] = "\(period.value) \(subscriptionUnitToString(period.unit))"

            if let intro = sub.introductoryOffer {
                map["introductory_offer"] = [
                    "price": intro.displayPrice,
                    "period": "\(intro.period.value) \(subscriptionUnitToString(intro.period.unit))",
                    "cycles": intro.periodCount
                ] as [String: Any]
            }

            if let trial = sub.introductoryOffer, trial.paymentMode == .freeTrial {
                map["trial_period"] = "\(trial.period.value) \(subscriptionUnitToString(trial.period.unit))"
            }
        }

        return map
    }

    /// Marshal a StoreKit Transaction to a JSON-compatible dictionary matching
    /// the `MobIap.Transaction` struct fields on the Elixir side.
    private static func transactionToMap(_ tx: Transaction) -> [String: Any] {
        let environment: String
        if #available(iOS 16.0, *) {
            environment = tx.environment == .sandbox ? "sandbox" : "production"
        } else {
            environment = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
                ? "sandbox" : "production"
        }

        var map: [String: Any] = [
            "id": String(tx.id),
            "product_id": tx.productID,
            "purchase_date": Int(tx.purchaseDate.timeIntervalSince1970 * 1000),
            "original_json": tx.jsonRepresentation.base64EncodedString(),
            "is_upgraded": tx.isUpgraded ? 1 : 0,
            "ownership_type": tx.ownershipType == .familyShared ? "family_shared" : "purchased",
            "environment": environment,
        ]

        if let expiresDate = tx.expirationDate {
            map["expires_date"] = Int(expiresDate.timeIntervalSince1970 * 1000)
        }

        return map
    }

    /// Map StoreKit product type to our string representation.
    private static func productTypeToString(_ type: Product.ProductType) -> String {
        switch type {
        case .consumable:     return "consumable"
        case .nonConsumable:  return "non_consumable"
        case .autoRenewable:  return "auto_renewable"
        case .nonRenewable:   return "non_renewing"
        default:              return "unknown"
        }
    }

    /// Map StoreKit subscription period unit to a readable string.
    private static func subscriptionUnitToString(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day:   return "day"
        case .week:  return "week"
        case .month: return "month"
        case .year:  return "year"
        @unknown default: return "unknown"
        }
    }
}
