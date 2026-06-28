import Foundation

/// L3：从 OCR（主）+ 视觉 tag（辅）推断敏感类型（全球证件，不限中国）
enum SensitiveTypeDetector {
    static func detect(ocrText: String?, visualTags: [String]? = nil) -> [String] {
        var types: [String] = []
        let text = normalize(ocrText)

        if isIDCard(text: text, visualTags: visualTags) {
            types.append("id_card")
        }
        if text.contains("银行卡")
            || text.contains("bank card")
            || text.contains("credit card")
            || text.contains("debit card") {
            types.append("bank_card")
        }
        if text.contains("护照") || text.contains("passport") {
            types.append("passport")
        }
        if text.contains("合同")
            || text.contains("invoice")
            || text.contains("receipt")
            || text.contains("发票") {
            types.append("document")
        }
        return Array(Set(types))
    }

    // MARK: - 政府 photo ID（各国身份证、驾照、国民 ID 等，护照走 passport）

    private static let idCardTitleKeywords = [
        // 中文
        "身份证", "居民身份证", "公民身份",
        // English
        "identity card", "identification card", "national id", "national identity",
        "identity document", "id card", "photo id", "photo identification",
        "driver's license", "drivers license", "driver license", "driving licence",
        "driving license", "learner permit",
        // 日本
        "身分証", "身分証明書", "運転免許", "運転経歴",
        // 韩国
        "주민등록증", "신분증", "운전면허",
        // 西班牙 / 拉美
        "documento de identidad", "documento nacional", "cédula", "cedula", "dni",
        // 葡萄牙 / 巴西
        "carteira de identidade", "carteira nacional", "registro geral",
        // 法语
        "carte d'identité", "carte identité", "carte nationale d'identité",
        "permis de conduire",
        // 德语
        "personalausweis", "ausweis", "führerschein", "fuehrerschein",
        // 意大利
        "carta d'identità", "carta identita", "patente di guida",
        // 荷兰
        "identiteitskaart", "identiteitsbewijs", "rijbewijs",
        // 印度
        "aadhaar", "aadhar", "uidai",
        // 东南亚
        "ktp", "kartu tanda penduduk", "mykad", "identity card no",
        // 俄语（常见 OCR 拉丁转写）
        "удостоверение личности",
    ]

    /// 各国证件正面常见字段（跨语言计数）
    private static let idCardFieldLabels = [
        // 中文
        "姓名", "性别", "民族", "出生", "住址", "公民", "公民身份号码", "签发",
        // English
        "surname", "given name", "given names", "date of birth", "place of birth",
        "nationality", "sex", "document no", "document number", "id no", "id number",
        "identity no", "identity number", "expires", "expiry", "valid until", "issuing",
        // French
        "nom", "prénom", "prenom", "né le", "ne le", "nationalité", "nationalite",
        // Spanish
        "nombre", "apellido", "apellidos", "fecha de nacimiento", "nacionalidad",
        // German
        "geburtsdatum", "geburtsort", "staatsangehörigkeit", "staatsangehoerigkeit",
        // Japanese
        "氏名", "生年月日", "国籍", "住所",
        // Korean
        "성명", "생년월일", "국적",
        // Portuguese
        "data de nascimento", "naturalidade",
    ]

    private static func isIDCard(text: String, visualTags: [String]?) -> Bool {
        if text.isEmpty {
            return false
        }

        if containsAny(text, idCardTitleKeywords) {
            return true
        }

        if hasIdentityDocumentMRZ(text) {
            return true
        }

        if hasChineseIDNumber(text) {
            return true
        }

        let labelHits = fieldLabelHits(text)

        if labelHits >= 3 {
            return true
        }

        if labelHits >= 2, hasPersonTag(visualTags) {
            return true
        }

        if labelHits >= 1, hasPersonTag(visualTags), hasDocumentLikeTag(visualTags) {
            return true
        }

        return false
    }

    /// TD1/TD2 身份证 MRZ（护照 P< 由 passport 类型处理）
    private static func hasIdentityDocumentMRZ(_ text: String) -> Bool {
        let upper = text.uppercased()
        if upper.contains("P<") {
            return false
        }
        let pattern = #"[IAC]\<[A-Z]{3}[A-Z0-9<]{20,}"#
        return upper.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hasChineseIDNumber(_ text: String) -> Bool {
        let pattern = #"[1-9]\d{5}(18|19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}[\dXx]"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// 供 OCR 精修策略使用
    static func containsChineseIDNumber(_ text: String) -> Bool {
        hasChineseIDNumber(normalize(text))
    }

    private static func fieldLabelHits(_ text: String) -> Int {
        idCardFieldLabels.filter { text.contains($0) }.count
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func hasPersonTag(_ visualTags: [String]?) -> Bool {
        let tags = Set((visualTags ?? []).map { $0.lowercased() })
        return !tags.isDisjoint(with: ["person", "people", "human", "adult"])
    }

    private static func hasDocumentLikeTag(_ visualTags: [String]?) -> Bool {
        let tags = Set((visualTags ?? []).map { $0.lowercased() })
        return !tags.isDisjoint(with: ["document", "printed_page", "text", "card"])
    }

    private static func normalize(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
