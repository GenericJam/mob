import Foundation
import Speech

@objcMembers
public final class MobSpeech: NSObject {
    private static var tasks: [SFSpeechRecognitionTask] = []

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
                completion(nil, "Speech recognition authorization: \(authorizationName(status)).")
                return
            }

            guard let recognizer = makeRecognizer(localeIdentifier: localeIdentifier) else {
                completion(nil, localeDiagnostic(localeIdentifier: localeIdentifier))
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
                    tasks.removeAll { $0.isFinishing || $0.isCancelled }
                    return
                }

                if let error {
                    completion(nil, "Speech transcription error for \(recognizer.locale.identifier): \(error.localizedDescription)")
                    tasks.removeAll { $0.isFinishing || $0.isCancelled }
                }
            }

            tasks.append(task)
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

    private static func makeRecognizer(localeIdentifier: String) -> SFSpeechRecognizer? {
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

    private static func localeDiagnostic(localeIdentifier: String) -> String {
        let requested = localeIdentifier.isEmpty ? "default locale" : localeIdentifier
        let supported = SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted()
            .prefix(12)
            .joined(separator: ", ")

        return "Failed to initialize speech recognizer for \(requested). Supported locales include: \(supported)."
    }

    private static func authorizationName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
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
