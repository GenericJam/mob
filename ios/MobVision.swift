import Foundation
import Vision

@objcMembers
public final class MobVision: NSObject {
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

    private static func decodeOptions(_ optionsJSON: String) -> [String: Any] {
        guard let data = optionsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }

        return dict
    }
}
