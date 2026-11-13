//
//  CSVCodec.swift
//  dime
//
//  App target only. RFC 4180 reading and writing, plus a reader for the CSV written by
//  the original Dime export (no quoting at all, commas stripped from notes only).
//

import Foundation

enum CSVCodec {
    static let legacyHeader = "Date,Note,Amount,Category,Type"
    static let byteOrderMark = "\u{FEFF}"

    // MARK: decoding

    /// Text of a file in UTF-8 (with or without BOM), UTF-16 or a legacy single-byte code page.
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        let bytes = [UInt8](data.prefix(3))

        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            if let text = String(data: data, encoding: .utf16) {
                return stripBOM(text)
            }
        }

        if let text = String(data: data, encoding: .utf8) {
            return stripBOM(text)
        }

        // Bank exports made on Windows.
        if let text = String(data: data, encoding: .windowsCP1251) {
            return text
        }

        return String(data: data, encoding: .isoLatin1)
    }

    static func stripBOM(_ text: String) -> String {
        if text.hasPrefix(byteOrderMark) {
            return String(text.dropFirst())
        }

        return text
    }

    // MARK: reading

    /// Comma, semicolon or tab: whichever is used most in the first lines.
    static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var lines = 0
        var inQuotes = false

        for character in text {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                if character == "\n" || character == "\r" || character == "\r\n" {
                    lines += 1

                    if lines >= 5 {
                        break
                    }
                } else if counts[character] != nil {
                    counts[character, default: 0] += 1
                }
            }
        }

        var best: Character = ","
        var bestCount = counts[","] ?? 0

        for candidate in [Character(";"), Character("\t")] {
            let count = counts[candidate] ?? 0

            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }

        return best
    }

    /// RFC 4180: quoted fields, doubled quotes, delimiters and line breaks inside quotes,
    /// LF / CR / CRLF row ends. Blank lines are dropped. Rows are not padded.
    static func parse(_ text: String, delimiter: Character = ",", quoting: Bool = true) -> [[String]] {
        let characters = Array(stripBOM(text))
        var rows = [[String]]()
        var row = [String]()
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var index = 0

        func endRow() {
            row.append(field)
            field = ""

            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) {
                rows.append(row)
            }

            row = []
            atFieldStart = true
        }

        while index < characters.count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }

                    inQuotes = false
                } else {
                    field.append(character)
                }

                index += 1
                continue
            }

            if quoting, character == "\"", atFieldStart {
                inQuotes = true
                atFieldStart = false
            } else if character == delimiter {
                row.append(field)
                field = ""
                atFieldStart = true
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                endRow()
            } else {
                field.append(character)
                atFieldStart = false
            }

            index += 1
        }

        if inQuotes {
            // A quote that never closes would swallow the rest of the file as one field.
            return parse(text, delimiter: delimiter, quoting: false)
        }

        if !field.isEmpty || !row.isEmpty {
            endRow()
        }

        return rows
    }

    /// Every row gets `count` fields (short rows are filled with ""), so column indexes are always valid.
    static func padded(_ rows: [[String]], to count: Int? = nil) -> [[String]] {
        let width = count ?? (rows.map { $0.count }.max() ?? 0)

        return rows.map { row in
            if row.count >= width {
                return row
            }

            return row + Array(repeating: "", count: width - row.count)
        }
    }

    // MARK: the original Dime export

    /// "2026-11-13 19:30:00 +0000," at the start of a line.
    private static func startsWithLegacyDate(_ line: String) -> Bool {
        let pattern = Array("dddd-dd-dd dd:dd:dd sdddd,")
        let characters = Array(line.prefix(pattern.count))

        guard characters.count == pattern.count else {
            return false
        }

        for (expected, actual) in zip(pattern, characters) {
            switch expected {
            case "d":
                guard actual.isASCII, actual.isNumber else { return false }
            case "s":
                guard actual == "+" || actual == "-" else { return false }
            default:
                guard actual == expected else { return false }
            }
        }

        return true
    }

    private static func lines(of text: String) -> [String] {
        stripBOM(text)
            .split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
            .map { String($0) }
    }

    /// True for a file written by the original app: its exact header and its UTC date format.
    static func isLegacyDimeExport(_ text: String) -> Bool {
        let all = lines(of: text)

        guard all.count >= 2, all[0].trimmingCharacters(in: .whitespaces) == legacyHeader else {
            return false
        }

        return startsWithLegacyDate(all[1])
    }

    /// Rows of exactly 5 fields (date, note, amount, category, type), header not included.
    /// The original export never quotes: a line that does not start with a date continues
    /// the note of the row above, and extra commas can only come from the category name.
    static func parseLegacyDime(_ text: String) -> [[String]] {
        var merged = [String]()

        for line in lines(of: text).dropFirst() {
            if startsWithLegacyDate(line) || merged.isEmpty {
                merged.append(line)
            } else {
                merged[merged.count - 1] += "\n" + line
            }
        }

        return merged.map { line in
            let fields = line.components(separatedBy: ",")

            guard fields.count > 5 else {
                return fields
            }

            let category = fields[3 ..< (fields.count - 1)].joined(separator: ",")

            return [fields[0], fields[1], fields[2], category, fields[fields.count - 1]]
        }
    }

    // MARK: writing

    /// One field, quoted when it holds a delimiter, a quote, a line break or outer spaces.
    static func field(_ value: String, delimiter: Character = ",") -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")

        guard needsQuotes else {
            return value
        }

        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String], delimiter: Character = ",") -> String {
        fields.map { field($0, delimiter: delimiter) }.joined(separator: String(delimiter))
    }
}
