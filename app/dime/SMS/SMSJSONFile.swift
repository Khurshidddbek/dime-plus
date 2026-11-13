//
//  SMSJSONFile.swift
//  dime
//
//  One JSON file of the SMS feature in the app group: { "version": 1, "items": [...] }.
//  No Core Data on purpose: the model is synced through CloudKit and its schema cannot be taken back.
//

import Foundation

private let smsFileVersion = 1

// One item that fails to decode (an enum value written by a newer build) must not take
// the whole file with it, so every item is decoded on its own.
private struct SMSLossyItem<Item: Decodable>: Decodable {
    let value: Item?

    init(from decoder: Decoder) throws {
        value = try? Item(from: decoder)
    }
}

private struct SMSEnvelopeIn<Item: Decodable>: Decodable {
    let version: Int
    let items: [SMSLossyItem<Item>]
}

private struct SMSEnvelopeOut<Item: Encodable>: Encodable {
    let version: Int
    let items: [Item]
}

enum SMSFileState {
    case loaded // read fine, or there was no file yet
    case unreadable // the file is there but could not be read or set aside: do not write over it
}

struct SMSJSONFile<Item: Codable> {
    let url: URL

    init(name: String, directory: URL = SMSFiles.directory) {
        url = directory.appendingPathComponent(name)
    }

    func load() -> (items: [Item], state: SMSFileState) {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return ([], .loaded)
        }

        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            // Most likely the phone was not unlocked since the restart. The content is fine, try again later.
            DiagnosticsLog.shared.log("sms", "\(url.lastPathComponent): cannot read, \(error.localizedDescription)")
            return ([], .unreadable)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        do {
            let envelope = try decoder.decode(SMSEnvelopeIn<Item>.self, from: data)
            let items = envelope.items.compactMap { $0.value }
            let dropped = envelope.items.count - items.count

            if dropped > 0 || envelope.version > smsFileVersion {
                // The next save would lose what this build cannot read: keep the original next to it.
                guard setAside(copy: true, tag: "v\(envelope.version)") else {
                    return ([], .unreadable)
                }

                DiagnosticsLog.shared.log("sms", "\(url.lastPathComponent): \(dropped) items not readable, original kept")
            }

            return (items, .loaded)
        } catch {
            DiagnosticsLog.shared.log("sms", "\(url.lastPathComponent): damaged, set aside")

            // Never overwrite a file that failed to decode: move it away and start a new one.
            let state: SMSFileState = setAside(copy: false, tag: "corrupt") ? .loaded : .unreadable

            return ([], state)
        }
    }

    @discardableResult
    func save(_ items: [Item]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        do {
            let data = try encoder.encode(SMSEnvelopeOut(version: smsFileVersion, items: items))

            // Readable after the first unlock, so a background run with a locked phone works.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            DiagnosticsLog.shared.log("sms", "\(url.lastPathComponent): write FAILED \(error.localizedDescription)")
            return false
        }
    }

    private func setAside(copy: Bool, tag: String) -> Bool {
        let fileManager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent + ".\(tag)-\(stamp).json"
        let target = url.deletingLastPathComponent().appendingPathComponent(name)

        do {
            if copy {
                try fileManager.copyItem(at: url, to: target)
            } else {
                try fileManager.moveItem(at: url, to: target)
            }

            return true
        } catch {
            DiagnosticsLog.shared.log("sms", "\(url.lastPathComponent): cannot set aside, \(error.localizedDescription)")
            return false
        }
    }
}

enum SMSFiles {
    static var directory: URL {
        AppFiles.sharedDirectory("Sms")
    }

    /// Removes everything the SMS feature stored (for "Erase all data").
    static func eraseAll() {
        let fileManager = FileManager.default
        let folder = directory

        if let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }

        SMSInboxStore.shared.reload()
        SMSRuleStore.shared.reload()
        SMSCardStore.shared.reload()
    }
}
