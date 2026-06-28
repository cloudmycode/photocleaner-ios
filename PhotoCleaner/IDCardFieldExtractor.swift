import Foundation

/// 从证件 OCR 中提取姓名、证号，便于本地按人名/号码检索（无需服务端参与）
enum IDCardFieldExtractor {
    struct Fields: Equatable {
        var name: String?
        var number: String?
    }

    static func extract(from ocrText: String) -> Fields {
        let raw = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Fields() }

        return Fields(
            name: extractName(from: raw) ?? extractNameFromMRZ(raw),
            number: extractNumber(from: raw)
        )
    }

    // MARK: - Name

    private static func extractName(from text: String) -> String? {
        if let chinese = matchFirst(in: text, pattern: #"姓名\s*[:：]?\s*([\p{Han}·]{2,8})"#) {
            return chinese
        }
        if let japanese = matchFirst(in: text, pattern: #"氏名\s*[:：]?\s*([\p{Han}\p{Hiragana}\p{Katakana}·\s]{2,16})"#) {
            return japanese.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let korean = matchFirst(in: text, pattern: #"성명\s*[:：]?\s*([\p{Hangul}\s]{2,16})"#) {
            return korean.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let surname = matchFirst(in: text, pattern: #"surname\s*[:/\s]+\s*([A-Za-z][A-Za-z'\-]+)"#) {
            let given = matchFirst(in: text, pattern: #"given\s+names?\s*[:/\s]+\s*([A-Za-z][A-Za-z'\-\s]+)"#)
            if let given, !given.isEmpty {
                return "\(given) \(surname)".trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return surname
        }
        if let nombre = matchFirst(in: text, pattern: #"(?:nombre|apellidos?)\s*[:：]?\s*([A-Za-zÁÉÍÓÚÜÑáéíóúüñ'\-\s]{2,40})"#) {
            return nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let nom = matchFirst(in: text, pattern: #"nom\s*[:：]?\s*([A-Za-zÀ-ÖØ-öø-ÿ'\-\s]{2,40})"#) {
            return nom.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 姓名与值分行：「姓名\n王洋」
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "姓名", index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikePersonName(next) {
                    return next
                }
            }
        }
        return nil
    }

    private static func extractNameFromMRZ(_ text: String) -> String? {
        let upper = text.uppercased()
        guard let line = upper.components(separatedBy: .newlines).first(where: { $0.contains("<<") }),
              line.hasPrefix("I<") || line.hasPrefix("ID") else {
            return nil
        }
        let parts = line.components(separatedBy: "<<")
        guard parts.count >= 2 else { return nil }
        let surname = parts[1].replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        let given = parts.count > 2
            ? parts[2].replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
            : ""
        let full = [given, surname].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? nil : full
    }

    // MARK: - Number

    private static func extractNumber(from text: String) -> String? {
        if let chinese = matchFirst(
            in: text,
            pattern: #"公民身份号码\s*[:：]?\s*([1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx])"#
        ) {
            return chinese.uppercased()
        }
        if let chinese = matchFirst(
            in: text,
            pattern: #"([1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx])"#
        ) {
            return chinese.uppercased()
        }
        if let labeled = matchFirst(
            in: text,
            pattern: #"(?:document|identity|id)\s*(?:no|number|#)?\s*[:#]?\s*([A-Z0-9\-]{6,20})"#
        ) {
            return labeled.uppercased()
        }
        return nil
    }

    private static func looksLikePersonName(_ text: String) -> Bool {
        guard (2...8).contains(text.count) else { return false }
        return text.range(of: #"^[\p{Han}·]{2,8}$"#, options: .regularExpression) != nil
            || text.range(of: #"^[A-Za-z][A-Za-z'\-\s]{1,30}$"#, options: .regularExpression) != nil
    }

    private static func matchFirst(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PhotoSearchIndexEntry {
    /// 检索用 OCR：原始全文 + 提取出的姓名/证号（便于「王洋的身份证」类查询）
    var searchableOCRText: String {
        [ocrText, idCardName, idCardNumber]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
    }
}
