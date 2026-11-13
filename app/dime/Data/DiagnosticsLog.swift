//
//  DiagnosticsLog.swift
//  dime
//
//  Compiled into all 4 targets (DataController logs through it). Foundation only.
//

import Foundation
import os

enum AppFiles {
    /// A folder inside the app group container. Falls back to the process' own
    /// Application Support when the group is not entitled, so callers never get nil.
    static func sharedDirectory(_ name: String) -> URL {
        let fileManager = FileManager.default
        let base = AppIdentifiers.appGroupContainerURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Rotating plain-text log in the app group (2 files of 512 KB).
/// `log` only enqueues, the file is opened and closed per line on a utility queue.
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "uz.khurshidbek.dime.diagnostics", qos: .utility)
    private let maxFileSize: UInt64 = 512 * 1024
    private let directory: URL
    private let processTag: String
    private let formatter: ISO8601DateFormatter
    private let logger = Logger(subsystem: AppIdentifiers.bundleID, category: "diagnostics")

    private var currentURL: URL { directory.appendingPathComponent("dime.log") }
    private var previousURL: URL { directory.appendingPathComponent("dime.1.log") }

    private init() {
        directory = AppFiles.sharedDirectory("Diagnostics")

        let path = Bundle.main.bundlePath
        if path.hasSuffix(".appex") {
            processTag = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            processTag = "app"
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        self.formatter = formatter
    }

    /// Current file first, then the rotated one. Either may not exist yet.
    var fileURLs: [URL] {
        [currentURL, previousURL]
    }

    func log(_ category: String, _ message: String) {
        let date = Date()

        queue.async {
            let flat = message.replacingOccurrences(of: "\n", with: " ")
            let line = "\(self.formatter.string(from: date)) [\(self.processTag)] \(category): \(flat)\n"
            self.logger.log("\(category, privacy: .public): \(flat, privacy: .public)")
            self.append(line)
        }
    }

    /// Blocks until everything logged so far is on disk.
    func flush() {
        queue.sync {}
    }

    /// Newest lines last.
    func recentLines(_ limit: Int = 200) -> [String] {
        queue.sync {
            var lines = [String]()

            for url in [previousURL, currentURL] {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                lines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }

            return Array(lines.suffix(max(limit, 0)))
        }
    }

    /// One merged text file in the temporary folder, ready for a share sheet.
    func exportURL() -> URL? {
        queue.sync {
            var text = "Dime diagnostics\n"
            text += "exported: \(formatter.string(from: Date()))\n"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            text += "version: \(version) (\(build))\n"
            text += "system: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
            text += "time zone: \(TimeZone.current.identifier)\n\n"

            for url in [previousURL, currentURL] {
                if let part = try? String(contentsOf: url, encoding: .utf8) {
                    text += part
                }
            }

            let stamp = formatter.string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: ".", with: "")
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("dime-diagnostics-\(stamp).txt")

            do {
                try Data(text.utf8).write(to: target, options: .atomic)
                return target
            } catch {
                return nil
            }
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: currentURL)
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    // Runs on `queue`.
    private func append(_ line: String) {
        let fileManager = FileManager.default
        let data = Data(line.utf8)

        if !fileManager.fileExists(atPath: currentURL.path) {
            try? data.write(to: currentURL, options: .atomic)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: currentURL)
            let size = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()

            if size + UInt64(data.count) > maxFileSize {
                try? fileManager.removeItem(at: previousURL)
                try? fileManager.moveItem(at: currentURL, to: previousURL)
            }
        } catch {
            // The log must never take the app down, a lost line is acceptable.
        }
    }
}
