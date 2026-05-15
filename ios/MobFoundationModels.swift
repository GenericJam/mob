import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

@objcMembers
public final class MobFoundationModels: NSObject {
    public static func generateText(
        _ prompt: String,
        optionsJSON: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        #if targetEnvironment(simulator)
        completion(nil, "Foundation Models does not run in the iOS simulator.")
        #else
        guard #available(iOS 26.0, *) else {
            completion(nil, "Foundation Models requires iOS 26.0 or newer.")
            return
        }

        #if canImport(FoundationModels)
        let opts = decodeOptions(optionsJSON)
        let instructions = opts["instructions"] as? String ?? ""
        let temperature = opts["temperature"] as? Double ?? 0.2
        let maximumResponseTokens = opts["maximum_response_tokens"] as? Int ?? 256

        Task {
            let model = SystemLanguageModel.default

            guard model.supportsLocale(Locale.current) else {
                completion(nil, "Foundation Models does not support the current locale: \(Locale.current.identifier).")
                return
            }

            switch model.availability {
            case .available:
                do {
                    let session = instructions.isEmpty
                        ? LanguageModelSession()
                        : LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(
                        to: prompt,
                        options: GenerationOptions(
                            temperature: temperature,
                            maximumResponseTokens: maximumResponseTokens
                        )
                    )
                    completion(response.content, nil)
                } catch {
                    completion(nil, "Foundation Models generation error: \(error.localizedDescription)")
                }

            case .unavailable(let reason):
                completion(nil, availabilityMessage(reason))
            }
        }
        #else
        completion(nil, "This build of Xcode does not expose the FoundationModels module.")
        #endif
        #endif
    }

    private static func decodeOptions(_ optionsJSON: String) -> [String: Any] {
        guard let data = optionsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }

        return dict
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func availabilityMessage(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Foundation Models unavailable: this device is not eligible for Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Foundation Models unavailable: Apple Intelligence is not enabled in Settings."
        case .modelNotReady:
            return "Foundation Models unavailable: the on-device model is not ready yet."
        @unknown default:
            return "Foundation Models unavailable: \(String(describing: reason))."
        }
    }
    #endif
}
