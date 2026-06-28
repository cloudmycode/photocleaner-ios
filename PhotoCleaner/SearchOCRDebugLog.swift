#if DEBUG
import Photos

/// Xcode 调试：智能搜索 OCR 索引日志（前缀 `[SearchOCR]`，可在控制台过滤）
enum SearchOCRDebugLog {
    static func info(_ message: String) {
        print("[SearchOCR] \(message)")
    }

    static func assetLabel(_ asset: PHAsset) -> String {
        let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
        let idPrefix = asset.localIdentifier.prefix(8)
        return "\(name) (\(idPrefix)…)"
    }

    static func preview(_ text: String, limit: Int = 100) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    static func logScanResult(
        index: Int,
        total: Int,
        asset: PHAsset,
        ocrText: String,
        visualTagCount: Int,
        sensitiveTypes: [String],
        idCardName: String?,
        idCardNumber: String?,
        imageLoaded: Bool,
        ocrMode: String = "fast"
    ) {
        let ocrLen = ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count
        var parts = [
            "\(index + 1)/\(total)",
            assetLabel(asset),
            "mode=\(ocrMode)",
            "load=\(imageLoaded ? "ok" : "fail")",
            "ocrLen=\(ocrLen)",
            "tags=\(visualTagCount)",
        ]
        if !sensitiveTypes.isEmpty {
            parts.append("sensitive=[\(sensitiveTypes.joined(separator: ","))]")
        }
        if let idCardName, !idCardName.isEmpty {
            parts.append("name=\(preview(idCardName, limit: 20))")
        }
        if let idCardNumber, !idCardNumber.isEmpty {
            parts.append("idNo=\(idCardNumber)")
        }
        if ocrLen > 0 {
            parts.append("text=\"\(preview(ocrText))\"")
        }
        info(parts.joined(separator: " | "))
    }

    static func logBatchSaved(count: Int, completed: Int, total: Int) {
        info("saved \(count) entries (\(completed)/\(total))")
    }
}
#endif
