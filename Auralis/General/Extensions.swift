//
//  Auralis
//
//  Created by Elsa on 2024/4/20.
//

import Cocoa
import Foundation
import UniformTypeIdentifiers

func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }

    let totalSeconds = max(Int(seconds), 0)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}

// MARK: - String Extensions
extension String {
    func subString(from startString: String, to endString: String) -> String {
        guard let startIndex = self.range(of: startString)?.upperBound else { return "" }
        let remainingString = String(self[startIndex...])
        guard let endIndex = remainingString.range(of: endString)?.lowerBound else {
            return remainingString
        }
        return String(remainingString[..<endIndex])
    }

    func subString(from startString: String) -> String {
        guard let startIndex = self.range(of: startString)?.upperBound else { return "" }
        return String(self[startIndex...])
    }

    func subString(to endString: String) -> String {
        guard let endIndex = self.range(of: endString)?.lowerBound else { return "" }
        return String(self[..<endIndex])
    }

    var https: String {
        starts(with: "http://") ? replacingOccurrences(of: "http://", with: "https://") : self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - URL Extensions
extension URL {
    var https: URL? {
        URL(string: absoluteString.https)
    }
}

// MARK: - Data Extensions
extension Data {
    func asType<T: Decodable>(
        _ type: T.Type,
        silent: Bool = false,
        source: String = #function
    ) -> T? {
        do {
            // JSONDecoder does not document concurrent use as safe. API calls are
            // frequently performed in task groups, so each decode gets its own
            // instance.
            return try JSONDecoder().decode(type, from: self)
        } catch {
            if !silent {
                let userFriendlyError = Self.decodingErrorDescription(
                    error,
                    targetType: type,
                    source: source
                )

                AlertModal.showAlertWithSaveOption(
                    LanguageManager.shared.string("general.decoding_error"),
                    userFriendlyError
                ) {
                    self.saveRawDataToFile()
                }
            }
            return nil
        }
    }

    private static func decodingErrorDescription<T>(
        _ error: Error,
        targetType: T.Type,
        source: String
    ) -> String {
        let summary: String

        switch error {
        case let DecodingError.keyNotFound(key, context):
            summary = "Missing key '\(key.stringValue)' at \(codingPath(context.codingPath))."
        case let DecodingError.valueNotFound(type, context):
            summary =
                "Missing \(String(describing: type)) value at \(codingPath(context.codingPath))."
        case let DecodingError.typeMismatch(type, context):
            summary =
                "Expected \(String(describing: type)) at \(codingPath(context.codingPath)): "
                + context.debugDescription
        case let DecodingError.dataCorrupted(context):
            summary =
                "Invalid data at \(codingPath(context.codingPath)): \(context.debugDescription)"
        default:
            summary = error.localizedDescription
        }

        return """
            Failed to decode \(String(describing: targetType)) in \(source).
            \(summary)

            Save the raw response to attach it to a bug report.
            """
    }

    private static func codingPath(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "<root>" }

        return path.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty {
                    result += "."
                }
                result += key.stringValue
            }
        }
    }

    private func saveRawDataToFile() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "raw_data_\(timestamp).json"

        // Use NSSavePanel to let user choose location
        let savePanel = NSSavePanel()
        savePanel.title = LanguageManager.shared.string("general.save_raw_data")
        savePanel.nameFieldStringValue = fileName
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        // Run the save panel
        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try self.write(to: url)

                // Show the file in Finder
                NSWorkspace.shared.selectFile(
                    url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)

                AlertModal.showAlert(LanguageManager.shared.string("alert.success"), String(format: LanguageManager.shared.string("general.raw_data_saved"), url.lastPathComponent))
            } catch {
                AlertModal.showAlert(
                    LanguageManager.shared.string("general.save_failed"), String(format: LanguageManager.shared.string("general.could_not_save"), error.localizedDescription))
            }
        }
    }

    func asAny() -> Any? {
        try? JSONSerialization.jsonObject(with: self, options: [])
    }

    func asJSONString() -> String {
        guard let jsonObject = asAny() else {
            return String(data: self, encoding: .utf8) ?? "Failed to decode as UTF-8"
        }

        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? "Failed to convert to string"
        } catch {
            return "Failed to serialize JSON: \(error.localizedDescription)"
        }
    }
}
