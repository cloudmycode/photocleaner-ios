import Foundation
import UIKit
import Vision

/// 搜索索引 OCR：按系统语言收窄识别语言；默认 fast，证件候选图再跑 accurate
enum SearchOCRSettings {
    /// 探针图最长边：分类 + OCR 门控
    static let maxImageProbeEdge = 384
    /// 识别 OCR 最长边（仅 OCR 阶段加载）
    static let maxImageEdge = 720
    /// 并行索引路数
    static let indexConcurrency = 3

    private static let ocrNoiseCharacters = CharacterSet(charactersIn: "*#@$%^&•¢¥…\"'`~|\\[]{}<>:;=_+·.,-")
    private static let classifyPeopleHints: Set<String> = [
        "person", "people", "human", "adult", "child", "baby", "man", "woman",
        "face", "portrait", "selfie", "head", "teen",
    ]
    /// 全库统计：几乎不出现在有价值 OCR 中
    private static let classifySceneryHints: Set<String> = [
        "landscape", "scenery", "mountain", "beach", "ocean", "sea", "lake", "river",
        "forest", "tree", "flower", "plant", "sky", "sunset", "sunrise", "cloud", "cloudy",
        "nature", "outdoor", "valley", "snow", "desert", "field", "grass", "meadow",
        "waterfall", "coast", "canyon", "glacier", "horizon", "wilderness", "garden",
        "park", "trail", "rock", "cliff", "island", "wave", "underwater", "coral",
        "blue_sky", "land", "hill", "shrub", "water", "water_body", "fence",
    ]
    /// 仅含 neutral tag 时跳过（如只有 gray / white / structure）
    private static let classifyNeutralHints: Set<String> = [
        "gray", "white", "black", "brown", "structure", "wood_processed", "monochrome",
        "pattern", "texture", "art", "orange", "blue", "yellow", "red", "green",
    ]

    /// 按手机语言偏好返回 Vision 识别语言（最多 4 个，减少乱码与耗时）
    static func recognitionLanguages() -> [String] {
        var codes: [String] = []

        func append(_ code: String) {
            guard !codes.contains(code) else { return }
            codes.append(code)
        }

        for identifier in Locale.preferredLanguages + [Locale.current.identifier] {
            mapLocale(identifier, append: append)
            if codes.count >= 4 { break }
        }

        if codes.isEmpty {
            append("en-US")
        }

        // 混合语言文档兜底
        if !codes.contains("en-US") {
            append("en-US")
        }

        return Array(codes.prefix(4))
    }

    private static let visualTextTagHints: Set<String> = [
        "text", "document", "printed_page", "card", "label", "sign", "poster",
        "business_card", "receipt", "envelope", "paper", "license", "menu",
        "book", "publication", "whiteboard", "handwriting", "calendar", "chart",
        "diagram", "illustrations", "screenshot",
    ]
    private static let classifyDocumentHints: Set<String> = visualTextTagHints

    struct OCRGateDecision {
        let shouldRun: Bool
        /// 调试：skip-scenery | skip-portrait | skip-neutral
        let skipMode: String
    }

    private static func normalizedTags(_ tags: [String]) -> Set<String> {
        Set(tags.map { $0.lowercased() })
    }

    /// 视觉分类已暗示可能有文字（避免漏掉证件/文档）
    static func visualTagsSuggestText(_ tags: [String]) -> Bool {
        let lower = Set(tags.map { $0.lowercased() })
        return !lower.isDisjoint(with: visualTextTagHints)
    }

    static func classificationSuggestsDocument(_ tags: [String]) -> Bool {
        let lower = Set(tags.map { $0.lowercased() })
        return !lower.isDisjoint(with: classifyDocumentHints)
    }

    static func classificationSuggestsPerson(_ tags: [String]) -> Bool {
        let lower = Set(tags.map { $0.lowercased() })
        return !lower.isDisjoint(with: classifyPeopleHints)
    }

    /// 人像或风景（Vision 分类 tag）
    static func classificationIsPortraitOrScenery(_ tags: [String]) -> Bool {
        let lower = Set(tags.map { $0.lowercased() })
        if !lower.isDisjoint(with: classifyPeopleHints) {
            return true
        }
        return !lower.isDisjoint(with: classifySceneryHints)
    }

    static func classificationSuggestsScenery(_ tags: [String]) -> Bool {
        !normalizedTags(tags).isDisjoint(with: classifySceneryHints)
    }

    static func classificationIsNeutralOnly(_ tags: [String]) -> Bool {
        let lower = normalizedTags(tags)
        return !lower.isEmpty && lower.isSubset(of: classifyNeutralHints)
    }

    /// 全库 JSON 统计 Rule D：document 白名单 → OCR；scenery/person/neutral → 跳过（证件文字区域兜底）
    static func ocrGateDecision(
        classificationTags: [String],
        isScreenshot: Bool,
        probeImage: CGImage,
        probeOrientation: CGImagePropertyOrientation
    ) -> OCRGateDecision {
        if isScreenshot {
            return OCRGateDecision(shouldRun: true, skipMode: "")
        }

        let tags = normalizedTags(classificationTags)
        if !tags.isDisjoint(with: classifyDocumentHints) {
            return OCRGateDecision(shouldRun: true, skipMode: "")
        }
        if !tags.isDisjoint(with: classifySceneryHints) {
            return OCRGateDecision(shouldRun: false, skipMode: "skip-scenery")
        }
        if !tags.isDisjoint(with: classifyPeopleHints) {
            return textRegionFallback(probeImage: probeImage, probeOrientation: probeOrientation, skipMode: "skip-portrait")
        }
        if classificationIsNeutralOnly(classificationTags) {
            return OCRGateDecision(shouldRun: false, skipMode: "skip-neutral")
        }
        return OCRGateDecision(shouldRun: true, skipMode: "")
    }

    static func shouldAttemptOCR(
        classificationTags: [String],
        isScreenshot: Bool,
        probeImage: CGImage,
        probeOrientation: CGImagePropertyOrientation
    ) -> Bool {
        ocrGateDecision(
            classificationTags: classificationTags,
            isScreenshot: isScreenshot,
            probeImage: probeImage,
            probeOrientation: probeOrientation
        ).shouldRun
    }

    private static func textRegionFallback(
        probeImage: CGImage,
        probeOrientation: CGImagePropertyOrientation,
        skipMode: String
    ) -> OCRGateDecision {
        if imageLikelyContainsText(
            cgImage: probeImage,
            orientation: probeOrientation,
            lenient: true
        ) {
            return OCRGateDecision(shouldRun: true, skipMode: "")
        }
        return OCRGateDecision(shouldRun: false, skipMode: skipMode)
    }

    static func imageLikelyContainsText(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        lenient: Bool = false
    ) -> Bool {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
        let confidenceFloor: Float = lenient ? 0.32 : 0.45
        let minimumBoxArea: CGFloat = lenient ? 0.00008 : 0.0002
        do {
            try handler.perform([request])
            guard let results = request.results, !results.isEmpty else { return false }
            return results.contains { observation in
                let box = observation.boundingBox
                let area = box.width * box.height
                return observation.confidence >= confidenceFloor && area >= minimumBoxArea
            }
        } catch {
            return false
        }
    }

    /// 无字图：仅 Vision 分类 tag（跳过人体框/取色，约为完整视觉分析的 1/3 耗时）
    static func lightweightVisualTags(from classification: [String]) -> [String] {
        var tags = Set(classification)
        let lower = Set(classification.map { $0.lowercased() })
        if !lower.isDisjoint(with: classifyPeopleHints) {
            tags.formUnion(["person", "people", "human"])
        }
        return tags.sorted()
    }

    /// 证件/文档类：即使 fast 像乱码也应用 720 accurate 再试一次
    static func shouldRetryAccurateDespiteGarbageFastText(
        fastText: String,
        visualTags: [String]
    ) -> Bool {
        if shouldRefineWithAccurate(fastText: fastText) {
            return true
        }
        if visualTagsSuggestText(visualTags) {
            return true
        }
        if classificationSuggestsDocument(visualTags) {
            return true
        }
        let lower = Set(visualTags.map { $0.lowercased() })
        return classificationSuggestsPerson(Array(lower))
            && !lower.isDisjoint(with: classifyDocumentHints.union(["text", "card", "document"]))
    }

    /// fast OCR 结果是否值得入库（过滤符号乱码；证件/证号始终保留）
    static func isUsefulSearchableOCR(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if SensitiveTypeDetector.containsChineseIDNumber(trimmed) {
            return true
        }
        if shouldRefineWithAccurate(fastText: trimmed) {
            return true
        }

        let quality = ocrQuality(of: trimmed)
        if quality.noiseRatio > 0.18 { return false }
        if quality.cjkCount >= 3, quality.noiseRatio <= 0.12 { return true }
        if quality.cjkCount >= 2, quality.noiseRatio <= 0.10 { return true }
        if quality.cjkCount == 0 {
            if quality.noiseRatio > 0.08 { return false }
            if quality.solidTokenCount < 2 { return false }
            return quality.meaningfulRatio >= 0.82
        }
        if quality.solidTokenCount >= 1, quality.cjkCount >= 1, quality.noiseRatio <= 0.12 {
            return true
        }
        return false
    }

    private struct OCRQuality {
        let meaningfulRatio: Double
        let noiseRatio: Double
        let cjkCount: Int
        let solidTokenCount: Int
    }

    private static func ocrQuality(of text: String) -> OCRQuality {
        var meaningful = 0
        var noise = 0
        var cjkCount = 0
        var total = 0

        for character in text {
            total += 1
            let string = String(character)
            if string.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                cjkCount += 1
                meaningful += 1
            } else if character.isLetter || character.isNumber {
                meaningful += 1
            } else if string.unicodeScalars.contains(where: { ocrNoiseCharacters.contains($0) }) {
                noise += 1
            }
        }

        let meaningfulRatio = total > 0 ? Double(meaningful) / Double(total) : 0
        let noiseRatio = total > 0 ? Double(noise) / Double(total) : 0
        let solidTokenCount = solidTokens(in: text).count
        return OCRQuality(
            meaningfulRatio: meaningfulRatio,
            noiseRatio: noiseRatio,
            cjkCount: cjkCount,
            solidTokenCount: solidTokenCount
        )
    }

    /// 连续 4+ 字母/数字/汉字片段，且片段内噪声符号占比低
    private static func solidTokens(in text: String) -> [String] {
        let pattern = #"[A-Za-z0-9\u4E00-\u9FFF]{4,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let token = String(text[swiftRange])
            let tokenNoise = token.unicodeScalars.filter { ocrNoiseCharacters.contains($0) }.count
            guard tokenNoise == 0 else { return nil }
            if token.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
                return token.count >= 2 ? token : nil
            }
            if token.allSatisfy(\.isNumber) {
                return token.count >= 6 ? token : nil
            }
            let letters = token.filter(\.isLetter)
            guard letters.count >= 4 else { return nil }
            let vowels = letters.filter { "aeiouAEIOU".contains($0) }
            guard !vowels.isEmpty else { return nil }
            return token
        }
    }

    /// fast 结果若像证件，再跑一次 accurate 精修（仅小比例照片）
    static func shouldRefineWithAccurate(fastText: String) -> Bool {
        let text = fastText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if SensitiveTypeDetector.containsChineseIDNumber(text) {
            return true
        }

        let lower = text.lowercased()
        let hints = [
            "身份证", "居民身份证", "公民身份", "姓名", "持证人", "结婚证",
            "identity card", "id card", "national id",
            "driver's license", "drivers license", "driving licence", "driving license",
            "driver license", "passport", "护照",
            "dni", "cédula", "cedula", "personalausweis",
        ]
        return hints.contains { lower.contains($0.lowercased()) }
    }

    static func visionOrientation(for image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func mapLocale(_ identifier: String, append: (String) -> Void) {
        let lower = identifier.lowercased().replacingOccurrences(of: "_", with: "-")

        switch true {
        case lower.hasPrefix("zh-hans"), lower.hasPrefix("zh-cn"), lower == "zh":
            append("zh-Hans")
        case lower.hasPrefix("zh-hant"), lower.hasPrefix("zh-tw"), lower.hasPrefix("zh-hk"), lower.hasPrefix("zh-mo"):
            append("zh-Hant")
            append("zh-Hans")
        case lower.hasPrefix("ja"):
            append("ja-JP")
        case lower.hasPrefix("ko"):
            append("ko-KR")
        case lower.hasPrefix("fr"):
            append("fr-FR")
        case lower.hasPrefix("de"):
            append("de-DE")
        case lower.hasPrefix("es"):
            append("es-ES")
        case lower.hasPrefix("pt"):
            append("pt-BR")
        case lower.hasPrefix("it"):
            append("it-IT")
        case lower.hasPrefix("ru"):
            append("ru-RU")
        case lower.hasPrefix("th"):
            append("th-TH")
        case lower.hasPrefix("vi"):
            append("vi-VN")
        case lower.hasPrefix("id"):
            append("id-ID")
        case lower.hasPrefix("ms"):
            append("ms-MY")
        case lower.hasPrefix("nl"):
            append("nl-NL")
        case lower.hasPrefix("pl"):
            append("pl-PL")
        case lower.hasPrefix("tr"):
            append("tr-TR")
        case lower.hasPrefix("ar"):
            append("ar-SA")
        case lower.hasPrefix("hi"):
            append("hi-IN")
        case lower.hasPrefix("en"):
            append("en-US")
        default:
            append("en-US")
        }
    }
}
