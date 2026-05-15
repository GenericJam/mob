import Foundation
import Speech
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

@objcMembers
public final class MobAI: NSObject {
    private static var speechTasks: [SFSpeechRecognitionTask] = []

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
                completion(nil, foundationAvailabilityMessage(reason))
            }
        }
        #else
        completion(nil, "This build of Xcode does not expose the FoundationModels module.")
        #endif
        #endif
    }

    public static func recognizeText(
        atPath path: String,
        optionsJSON: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard FileManager.default.fileExists(atPath: path) else {
                completion(nil, "Image file does not exist: \(path)")
                return
            }

            let opts = decodeOptions(optionsJSON)
            let url = URL(fileURLWithPath: path)
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    completion(nil, "Vision OCR error: \(error.localizedDescription)")
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                completion(lines.joined(separator: "\n"), nil)
            }

            let level = opts["recognition_level"] as? String ?? "accurate"
            request.recognitionLevel = level == "fast" ? .fast : .accurate
            request.usesLanguageCorrection = opts["uses_language_correction"] as? Bool ?? true
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(url: url, options: [:]).perform([request])
            } catch {
                completion(nil, "Vision OCR error: \(error.localizedDescription)")
            }
        }
    }

    public static func transcribeAudio(
        atPath path: String,
        optionsJSON: String,
        completion: @escaping (String?, String?) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: path) else {
            completion(nil, "Speech audio file does not exist: \(path)")
            return
        }

        let opts = decodeOptions(optionsJSON)
        let localeIdentifier = opts["locale"] as? String ?? ""
        let requiresOnDeviceRecognition = opts["requires_on_device_recognition"] as? Bool ?? false
        let url = URL(fileURLWithPath: path)

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(nil, "Speech recognition authorization: \(speechAuthorizationName(status)).")
                return
            }

            guard let recognizer = makeSpeechRecognizer(localeIdentifier: localeIdentifier) else {
                completion(nil, speechLocaleDiagnostic(localeIdentifier: localeIdentifier))
                return
            }

            guard recognizer.isAvailable else {
                completion(nil, "Speech recognizer for \(recognizer.locale.identifier) is not currently available.")
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    completion(result.bestTranscription.formattedString, nil)
                    speechTasks.removeAll { $0.isFinishing || $0.isCancelled }
                    return
                }

                if let error {
                    completion(nil, "Speech transcription error for \(recognizer.locale.identifier): \(error.localizedDescription)")
                    speechTasks.removeAll { $0.isFinishing || $0.isCancelled }
                }
            }

            speechTasks.append(task)
        }
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
    private static func foundationAvailabilityMessage(
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

    private static func makeSpeechRecognizer(localeIdentifier: String) -> SFSpeechRecognizer? {
        if !localeIdentifier.isEmpty {
            return SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        }

        if let recognizer = SFSpeechRecognizer() {
            return recognizer
        }

        let preferredIdentifiers = [
            Locale.current.identifier,
            Locale.preferredLanguages.first ?? "",
            "en-US",
            "en_US"
        ]

        for identifier in preferredIdentifiers where !identifier.isEmpty {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier)) {
                return recognizer
            }
        }

        return nil
    }

    private static func speechLocaleDiagnostic(localeIdentifier: String) -> String {
        let requested = localeIdentifier.isEmpty ? "default locale" : localeIdentifier
        let supported = SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted()
            .prefix(12)
            .joined(separator: ", ")

        return "Failed to initialize speech recognizer for \(requested). Supported locales include: \(supported)."
    }

    private static func speechAuthorizationName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not determined"
        @unknown default:
            return "unknown"
        }
    }
}
