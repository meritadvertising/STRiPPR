import Foundation
import StripprCore
import Darwin

/// Headless entry point using the exact engine shipped in the native app.
@main
struct StripprCLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let operation = args.first, ["scan", "clean"].contains(operation) else {
            usage(); exit(2)
        }
        args.removeFirst()
        var paths: [String] = []
        var output: URL?
        var cancelThreshold: Double?
        var keepEncoderInfo = true
        var replaceOriginal = false
        var replacementConfirmed = false
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--output":
                guard !args.isEmpty else { usage(); exit(2) }
                output = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
            case "--remove-encoder-info":
                keepEncoderInfo = false
            case "--replace-original":
                replaceOriginal = true
            case "--confirm-replacement":
                replacementConfirmed = true
            case "--cancel-after-progress":
                guard !args.isEmpty, let value = Double(args.removeFirst()), (0...1).contains(value) else {
                    usage(); exit(2)
                }
                cancelThreshold = value
            case "--":
                paths.append(contentsOf: args); args.removeAll()
            default:
                guard !arg.hasPrefix("--") else { usage(); exit(2) }
                paths.append(arg)
            }
        }
        guard !paths.isEmpty else { usage(); exit(2) }
        if operation != "clean" && (replaceOriginal || replacementConfirmed) {
            usageError("Replacement flags are available only for clean.")
        }
        if replaceOriginal && !replacementConfirmed {
            usageError("--replace-original requires --confirm-replacement. The original files have not been changed.")
        }
        if replacementConfirmed && !replaceOriginal {
            usageError("--confirm-replacement requires --replace-original.")
        }
        if replaceOriginal && output != nil {
            usageError("--output cannot be combined with --replace-original; replacements stay at their original paths.")
        }
        var failed = false
        var cancelled = false
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let token = CancellationToken()
            do {
                let scan = try MediaScanner.scan(url: url, cancellation: token, keepEncoderInfo: keepEncoderInfo)
                var record = scanRecord(scan)
                if operation == "clean" {
                    let threshold = cancelThreshold
                    let result = try MediaCleaner.clean(scan, outputDirectory: output, replaceOriginal: replaceOriginal, cancellation: token) { value, stage in
                        if let threshold, value >= threshold { token.cancel() }
                    }
                    record["operation"] = "clean"
                    record["output"] = result.outputURL.path
                    record["removedTagCount"] = result.removedTagCount
                    record["verifiedBytes"] = result.verifiedBytes
                    record["didReplaceOriginal"] = result.didReplaceOriginal
                    record["warnings"] = scan.warnings + result.warnings
                    if let recovery = result.recoveryURL { record["recoveryURL"] = recovery.path }
                    record["status"] = "verified"
                }
                emit(record)
            } catch {
                if case StripprError.cancelled = error { cancelled = true }
                failed = true
                emit(["operation": operation, "path": url.path, "status": token.isCancelled ? "cancelled" : "failed", "error": error.localizedDescription, "keepEncoderInfo": keepEncoderInfo, "replacementRequested": replaceOriginal])
            }
        }
        if cancelled { exit(130) }
        if failed { exit(1) }
    }

    static func scanRecord(_ scan: ScanResult) -> [String: Any] {
        ["operation": "scan", "path": scan.url.path, "format": scan.format,
         "fileSize": scan.fileSize, "canClean": scan.canClean,
         "removableTagCount": scan.removableTagCount, "keepEncoderInfo": scan.keepEncoderInfo,
         "tags": scan.tags.map { ["key": $0.key, "value": $0.value, "removable": $0.removable, "reason": $0.reason] as [String: Any] },
         "warnings": scan.warnings,
         "edits": scan.edits.map { ["offset": $0.offset, "length": $0.length] },
         "status": "scanned"]
    }

    static func emit(_ record: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Could not encode result: \(error.localizedDescription)\n".utf8))
        }
    }

    static func usageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        usage()
        exit(2)
    }

    static func usage() {
        FileHandle.standardError.write(Data("Usage: strippr-cli scan [--remove-encoder-info] FILE… | clean [--remove-encoder-info] [--output DIRECTORY | --replace-original --confirm-replacement] [--cancel-after-progress 0…1] FILE…\n".utf8))
    }
}
