import Foundation

/// 客户端从用户原话补全 OCR 检索条件（服务端只需返回 id_card 等 sensitiveTypes）
enum SmartSearchQueryParser {
    static func enrichPlan(_ plan: SearchPlan, originalQuery: String) -> SearchPlan {
        var updated = plan
        let sensitive = Set(plan.must?.sensitiveTypes ?? [])
        guard !sensitive.isEmpty else { return plan }

        var localTerms: [String] = []
        if sensitive.contains("id_card") {
            localTerms.append(contentsOf: extractIDCardTerms(from: originalQuery))
        }
        if sensitive.contains("bank_card") {
            localTerms.append(contentsOf: extractBankCardTail(from: originalQuery))
        }

        localTerms = uniqueTerms(localTerms)
        guard !localTerms.isEmpty else { return updated }

        var must = updated.must ?? SearchMust()
        var combined = must.ocrContainsAll ?? []
        for term in localTerms where !combined.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            combined.append(term)
        }
        must.ocrContainsAll = combined
        updated.must = must
        return updated
    }

    // MARK: - ID card query

    private static let idCardStopPhrases = [
        "的身份证", "身份证件", "身份证照片", "身份证图片", "身份证扫描", "身份证",
        "的证件", "证件照", "证件照片",
        "identity card", "identification card", "id card", "photo id", "national id",
        "driver's license", "drivers license", "driver license", "driving licence",
        "driving license",
        "身分証", "身分証明書", "運転免許",
        "주민등록증", "신분증",
    ]

    private static let queryStopWords: Set<String> = [
        "找", "查", "搜", "搜索", "我要", "帮我", "请", "我的", "所有", "全部",
        "find", "search", "show", "look", "for", "my", "the", "a", "an",
    ]

    private static func extractIDCardTerms(from query: String) -> [String] {
        var terms: [String] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let number = extractChineseIDNumber(from: trimmed) {
            terms.append(number)
        }

        var text = trimmed
        for phrase in idCardStopPhrases.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: phrase, with: " ", options: [.caseInsensitive])
        }

        text = text.replacingOccurrences(
            of: #"[^\p{L}\p{N}\s·'-]"#,
            with: " ",
            options: .regularExpression
        )

        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard token.count >= 2 else { return false }
                if queryStopWords.contains(token.lowercased()) { return false }
                if idCardStopPhrases.contains(where: { token.caseInsensitiveCompare($0) == .orderedSame }) {
                    return false
                }
                return true
            }

        terms.append(contentsOf: tokens)
        return terms
    }

    private static func extractBankCardTail(from query: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{4})\s*$"#),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let range = Range(match.range(at: 1), in: query) else {
            return []
        }
        return [String(query[range])]
    }

    private static func extractChineseIDNumber(from text: String) -> String? {
        let pattern = #"[1-9]\d{5}(?:18|19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(text[range]).uppercased()
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let key = term.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(term)
        }
        return result
    }
}
