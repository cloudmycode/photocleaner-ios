import CryptoKit
import Foundation
import Photos

struct PhotoSearchIndexEntry: Codable {
    let id: String
    let signature: String
    let mediaType: String
    let assetTypes: [String]
    let creationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let storageBytes: Int64
    var visualTags: [String]?
    var visualIndexedAt: Date?
    var ocrText: String?
    var ocrIndexedAt: Date?
    var sensitiveTypes: [String]?
    var idCardName: String?
    var idCardNumber: String?
}

struct PhotoSearchIndexSnapshot {
    let tagPostings: [String: Set<String>]
    let sensitivePostings: [String: Set<String>]
}

struct PhotoSearchDebugExport: Codable {
    let exportedAt: Date
    let algorithmVersion: Int
    let assetCount: Int
    let indexedAssetCount: Int
    let missingVisualTagCount: Int
    let missingOCRCount: Int
    let pendingOCRCount: Int
    let idCardCount: Int
    let searchInputs: [String]
    let entries: [PhotoSearchDebugExportEntry]
}

struct PhotoSearchDebugExportEntry: Codable {
    let localIdentifier: String
    let filename: String?
    let signature: String
    let hasValidIndex: Bool
    let mediaType: String
    let assetTypes: [String]
    let creationDate: Date?
    let latitude: Double?
    let longitude: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let storageBytes: Int64
    let visualTags: [String]
    let visualIndexedAt: Date?
    let ocrText: String?
    let ocrIndexedAt: Date?
    let sensitiveTypes: [String]
    let idCardName: String?
    let idCardNumber: String?
}

actor PhotoSearchIndexStore {
    private struct Payload: Codable {
        let version: Int
        var entries: [String: PhotoSearchIndexEntry]
    }

    static let shared = PhotoSearchIndexStore()

    private let algorithmVersion = 6
    private let fileURL: URL
    private var entries: [String: PhotoSearchIndexEntry]?
    private var tagPostings: [String: Set<String>] = [:]
    private var sensitivePostings: [String: Set<String>] = [:]

    init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "PhotoSearchIndex",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("index.json")
    }

    func validEntries(for assets: [PHAsset]) -> [String: PhotoSearchIndexEntry] {
        loadIfNeeded()
        guard let entries else { return [:] }
        return Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            let id = asset.localIdentifier
            guard let entry = entries[id],
                  entry.signature == Self.signature(for: asset) else {
                return nil
            }
            return (id, entry)
        })
    }

    func searchIndex() -> PhotoSearchIndexSnapshot {
        loadIfNeeded()
        return PhotoSearchIndexSnapshot(
            tagPostings: tagPostings,
            sensitivePostings: sensitivePostings
        )
    }

    func rebuildMetadata(for assets: [PHAsset]) throws {
        loadIfNeeded()
        let existing = entries ?? [:]
        let activeIDs = Set(assets.map(\.localIdentifier))
        var updated: [String: PhotoSearchIndexEntry] = [:]
        updated.reserveCapacity(assets.count)

        for asset in assets {
            let id = asset.localIdentifier
            let signature = Self.signature(for: asset)
            let previous = existing[id]
            let canReuse = previous?.signature == signature
            var entry = Self.entry(
                for: asset,
                signature: signature,
                previousVisualTags: canReuse ? previous?.visualTags : nil,
                previousVisualIndexedAt: canReuse ? previous?.visualIndexedAt : nil,
                previousOCRText: canReuse ? previous?.ocrText : nil,
                previousOCRIndexedAt: canReuse ? previous?.ocrIndexedAt : nil,
                previousSensitiveTypes: canReuse ? previous?.sensitiveTypes : nil
            )
            if canReuse, let previous {
                entry.idCardName = previous.idCardName
                entry.idCardNumber = previous.idCardNumber
            }
            updated[id] = entry
        }

        entries = updated.filter { activeIDs.contains($0.key) }
        rebuildPostings()
        try save()
    }

    func assetsNeedingOCR(from assets: [PHAsset]) -> [PHAsset] {
        loadIfNeeded()
        let existing = entries ?? [:]
        return assets.filter { asset in
            guard asset.mediaType == .image else { return false }
            let entry = existing[asset.localIdentifier]
            return entry?.signature != Self.signature(for: asset) ||
                entry?.ocrIndexedAt == nil
        }
    }

#if DEBUG
    func ocrIndexDebugSummary(for assets: [PHAsset]) -> String {
        loadIfNeeded()
        let existing = entries ?? [:]
        var pending = 0
        var goodOCR = 0
        for asset in assets where asset.mediaType == .image {
            let entry = existing[asset.localIdentifier]
            if entry?.ocrIndexedAt == nil {
                pending += 1
            } else if (entry?.ocrText ?? "").count > 50 {
                goodOCR += 1
            }
        }
        return "pending=\(pending) goodOCR=\(goodOCR) totalImages=\(assets.count)"
    }
#endif

    func updateOCRText(_ text: String, for asset: PHAsset) throws {
        loadIfNeeded()
        upsertOCRText(text, for: asset)
        try save()
    }

    func updateOCRTexts(_ values: [(asset: PHAsset, text: String)]) throws {
        guard !values.isEmpty else { return }
        loadIfNeeded()
        for value in values {
            upsertOCRText(value.text, for: value.asset)
        }
        try save()
    }

    func imageAssetsNeedingVisualIndex(from assets: [PHAsset]) -> [PHAsset] {
        loadIfNeeded()
        let existing = entries ?? [:]
        return assets.filter { asset in
            guard asset.mediaType == .image else { return false }
            let entry = existing[asset.localIdentifier]
            return entry?.signature != Self.signature(for: asset) ||
                entry?.visualIndexedAt == nil
        }
    }

    func updateVisualTags(_ tags: [String], for asset: PHAsset) throws {
        loadIfNeeded()
        upsertVisualTags(tags, for: asset)
        try save()
    }

    func updateVisualAnalyses(_ values: [(asset: PHAsset, visualTags: [String])]) throws {
        guard !values.isEmpty else { return }
        loadIfNeeded()
        for value in values {
            upsertVisualTags(value.visualTags, for: value.asset)
        }
        try save()
    }

    func updateSearchAnalyses(
        _ values: [(asset: PHAsset, ocrText: String, visualTags: [String])]
    ) throws {
        guard !values.isEmpty else { return }
        loadIfNeeded()
        for value in values {
            upsertSearchAnalysis(
                ocrText: value.ocrText,
                visualTags: value.visualTags,
                for: value.asset
            )
        }
        try save()
    }

    func clear() throws {
        entries = [:]
        tagPostings = [:]
        sensitivePostings = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func sizeInBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ) else {
            return 0
        }
        return attributes[.size] as? Int64 ?? 0
    }

    /// 本机 visualTags 去重列表，按倒排文档频次降序。
    func topVisualTags(limit: Int = 1000) -> [String] {
        loadIfNeeded()
        guard limit > 0 else { return [] }

        return tagPostings
            .sorted {
                if $0.value.count != $1.value.count {
                    return $0.value.count > $1.value.count
                }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map(\.key)
    }

    func exportDebugSnapshot(for assets: [PHAsset]) throws -> URL {
        loadIfNeeded()

        let rows = assets.map { asset -> PhotoSearchDebugExportEntry in
            let signature = Self.signature(for: asset)
            let current = currentEntry(for: asset, signature: signature)
            let entry = current ?? Self.entry(
                for: asset,
                signature: signature,
                previousVisualTags: nil,
                previousVisualIndexedAt: nil,
                previousOCRText: nil,
                previousOCRIndexedAt: nil,
                previousSensitiveTypes: nil
            )

            return PhotoSearchDebugExportEntry(
                localIdentifier: asset.localIdentifier,
                filename: PHAssetResource.assetResources(for: asset).first?.originalFilename,
                signature: signature,
                hasValidIndex: current != nil,
                mediaType: entry.mediaType,
                assetTypes: entry.assetTypes,
                creationDate: entry.creationDate,
                latitude: entry.latitude,
                longitude: entry.longitude,
                pixelWidth: entry.pixelWidth,
                pixelHeight: entry.pixelHeight,
                storageBytes: entry.storageBytes,
                visualTags: entry.visualTags ?? [],
                visualIndexedAt: entry.visualIndexedAt,
                ocrText: entry.ocrText,
                ocrIndexedAt: entry.ocrIndexedAt,
                sensitiveTypes: entry.sensitiveTypes
                    ?? SensitiveTypeDetector.detect(
                        ocrText: entry.ocrText,
                        visualTags: entry.visualTags
                    ),
                idCardName: entry.idCardName,
                idCardNumber: entry.idCardNumber
            )
        }

        let export = PhotoSearchDebugExport(
            exportedAt: Date(),
            algorithmVersion: algorithmVersion,
            assetCount: rows.count,
            indexedAssetCount: rows.count { $0.hasValidIndex },
            missingVisualTagCount: rows.count { $0.visualTags.isEmpty },
            missingOCRCount: rows.count {
                ($0.ocrText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            },
            pendingOCRCount: rows.count { $0.ocrIndexedAt == nil },
            idCardCount: rows.count { $0.sensitiveTypes.contains("id_card") },
            searchInputs: [
                "visualTags",
                "ocrText",
                "idCardName",
                "idCardNumber",
                "sensitiveTypes",
                "creationDate",
                "location",
                "mediaType",
                "assetTypes",
                "storageBytes"
            ],
            entries: rows
        )

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSearchDebugExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let fileURL = exportDirectory.appendingPathComponent(
            "smart-search-index-\(Self.exportTimestampString(export.exportedAt)).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == algorithmVersion else {
            entries = [:]
            rebuildPostings()
            return
        }
        entries = payload.entries
        rebuildPostings()
    }

    private func applyIDCardFields(to entry: inout PhotoSearchIndexEntry) {
        guard entry.sensitiveTypes?.contains("id_card") == true,
              let ocr = entry.ocrText,
              !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            entry.idCardName = nil
            entry.idCardNumber = nil
            return
        }
        let fields = IDCardFieldExtractor.extract(from: ocr)
        entry.idCardName = fields.name
        entry.idCardNumber = fields.number
    }

    private func save() throws {
        let data = try JSONEncoder().encode(
            Payload(version: algorithmVersion, entries: entries ?? [:])
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func upsertSearchAnalysis(
        ocrText: String,
        visualTags: [String],
        for asset: PHAsset
    ) {
        let id = asset.localIdentifier
        let signature = Self.signature(for: asset)
        let previous = currentEntry(for: asset, signature: signature)
        let sensitive = SensitiveTypeDetector.detect(ocrText: ocrText, visualTags: visualTags)

        patchTagPostings(photoId: id, oldTags: previous?.visualTags, newTags: visualTags)
        patchSensitivePostings(
            photoId: id,
            oldTypes: previous?.sensitiveTypes,
            newTypes: sensitive
        )

        var entry = Self.entry(
            for: asset,
            signature: signature,
            previousVisualTags: visualTags,
            previousVisualIndexedAt: Date(),
            previousOCRText: ocrText,
            previousOCRIndexedAt: Date(),
            previousSensitiveTypes: sensitive.isEmpty ? nil : sensitive
        )
        entry.visualTags = visualTags
        entry.visualIndexedAt = Date()
        entry.ocrText = ocrText
        entry.ocrIndexedAt = Date()
        entry.sensitiveTypes = sensitive.isEmpty ? nil : sensitive
        applyIDCardFields(to: &entry)
        entries?[id] = entry
#if DEBUG
        if sensitive.contains("id_card") {
            SearchOCRDebugLog.info(
                "indexed id_card | \(SearchOCRDebugLog.assetLabel(asset)) | name=\(entry.idCardName ?? "-") | idNo=\(entry.idCardNumber ?? "-")"
            )
        }
#endif
    }

    private func upsertOCRText(_ text: String, for asset: PHAsset) {
        let id = asset.localIdentifier
        let signature = Self.signature(for: asset)
        let previous = currentEntry(for: asset, signature: signature)
        let tags = previous?.visualTags ?? []
        let sensitive = SensitiveTypeDetector.detect(ocrText: text, visualTags: tags)
        var entry = Self.entry(
            for: asset,
            signature: signature,
            previousVisualTags: previous?.visualTags,
            previousVisualIndexedAt: previous?.visualIndexedAt,
            previousOCRText: text,
            previousOCRIndexedAt: Date(),
            previousSensitiveTypes: sensitive.isEmpty ? nil : sensitive
        )
        entry.ocrText = text
        entry.ocrIndexedAt = Date()
        entry.sensitiveTypes = sensitive.isEmpty ? nil : sensitive
        applyIDCardFields(to: &entry)
        patchSensitivePostings(photoId: id, oldTypes: previous?.sensitiveTypes, newTypes: sensitive)
        entries?[id] = entry
    }

    private func upsertVisualTags(_ tags: [String], for asset: PHAsset) {
        let id = asset.localIdentifier
        let signature = Self.signature(for: asset)
        let previous = currentEntry(for: asset, signature: signature)
        var entry = Self.entry(
            for: asset,
            signature: signature,
            previousVisualTags: tags,
            previousVisualIndexedAt: Date(),
            previousOCRText: previous?.ocrText,
            previousOCRIndexedAt: previous?.ocrIndexedAt,
            previousSensitiveTypes: previous?.sensitiveTypes
        )
        entry.visualTags = tags
        entry.visualIndexedAt = Date()
        patchTagPostings(photoId: id, oldTags: previous?.visualTags, newTags: tags)
        entries?[id] = entry
    }

    private func currentEntry(
        for asset: PHAsset,
        signature: String
    ) -> PhotoSearchIndexEntry? {
        guard let entry = entries?[asset.localIdentifier],
              entry.signature == signature else {
            return nil
        }
        return entry
    }

    private static func entry(
        for asset: PHAsset,
        signature: String,
        previousVisualTags: [String]?,
        previousVisualIndexedAt: Date?,
        previousOCRText: String?,
        previousOCRIndexedAt: Date?,
        previousSensitiveTypes: [String]?
    ) -> PhotoSearchIndexEntry {
        PhotoSearchIndexEntry(
            id: asset.localIdentifier,
            signature: signature,
            mediaType: asset.mediaType == .video ? "video" : "image",
            assetTypes: assetTypes(for: asset),
            creationDate: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            storageBytes: storageBytes(for: asset),
            visualTags: previousVisualTags,
            visualIndexedAt: previousVisualIndexedAt,
            ocrText: previousOCRText,
            ocrIndexedAt: previousOCRIndexedAt,
            sensitiveTypes: previousSensitiveTypes,
            idCardName: nil,
            idCardNumber: nil
        )
    }

    private func rebuildPostings() {
        tagPostings = [:]
        sensitivePostings = [:]
        guard let entries else { return }
        for entry in entries.values {
            insertPostings(for: entry)
        }
    }

    private func insertPostings(for entry: PhotoSearchIndexEntry) {
        let id = entry.id
        for tag in entry.visualTags ?? [] {
            tagPostings[tag, default: []].insert(id)
        }
        for type in entry.sensitiveTypes ?? [] {
            sensitivePostings[type, default: []].insert(id)
        }
    }

    private func patchTagPostings(photoId: String, oldTags: [String]?, newTags: [String]) {
        for tag in oldTags ?? [] {
            tagPostings[tag]?.remove(photoId)
            if tagPostings[tag]?.isEmpty == true {
                tagPostings.removeValue(forKey: tag)
            }
        }
        for tag in newTags {
            tagPostings[tag, default: []].insert(photoId)
        }
    }

    private func patchSensitivePostings(
        photoId: String,
        oldTypes: [String]?,
        newTypes: [String]
    ) {
        for type in oldTypes ?? [] {
            sensitivePostings[type]?.remove(photoId)
            if sensitivePostings[type]?.isEmpty == true {
                sensitivePostings.removeValue(forKey: type)
            }
        }
        for type in newTypes {
            sensitivePostings[type, default: []].insert(photoId)
        }
    }

    private static func assetTypes(for asset: PHAsset) -> [String] {
        var types: [String] = []
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            types.append("screenshot")
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            types.append("live")
        }
        if asset.mediaSubtypes.contains(.videoScreenRecording) {
            types.append("screen_recording")
        }
        return types
    }

    private static func exportTimestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func signature(for asset: PHAsset) -> String {
        [
            asset.localIdentifier,
            String(format: "%.3f", asset.creationDate?.timeIntervalSince1970 ?? 0),
            String(format: "%.3f", asset.modificationDate?.timeIntervalSince1970 ?? 0),
            String(asset.pixelWidth),
            String(asset.pixelHeight),
            String(asset.mediaType.rawValue),
            String(asset.mediaSubtypes.rawValue)
        ].joined(separator: ":")
    }

    private static func storageBytes(for asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { total, resource in
            if let fileSize = resource.value(forKey: "fileSize") as? NSNumber {
                return total + fileSize.int64Value
            }
            return total
        }
    }
}

struct CachedSimilarAsset: Codable {
    let id: String
    let qualityScore: Double
    let isBest: Bool
}

struct CachedSimilarGroup: Codable {
    let signature: String
    let assets: [CachedSimilarAsset]
}

actor SimilarAnalysisCache {
    private struct Payload: Codable {
        let version: Int
        var groups: [String: CachedSimilarGroup]
    }

    private let algorithmVersion = 4
    private let fileURL: URL
    private var groups: [String: CachedSimilarGroup]?

    init() {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "SimilarAnalysis",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("groups.json")
    }

    func group(for signature: String) -> CachedSimilarGroup? {
        loadIfNeeded()
        return groups?[signature]
    }

    func replace(
        with newGroups: [String: CachedSimilarGroup]
    ) throws {
        groups = newGroups
        let payload = Payload(version: algorithmVersion, groups: newGroups)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        groups = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func sizeInBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ) else {
            return 0
        }
        return attributes[.size] as? Int64 ?? 0
    }

    private func loadIfNeeded() {
        guard groups == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == algorithmVersion else {
            groups = [:]
            return
        }
        groups = payload.groups
    }
}

enum SimilarAnalysisSignature {
    static func make(for assets: [PHAsset]) -> String {
        let source = assets.map { asset in
            [
                asset.localIdentifier,
                timestamp(asset.creationDate),
                timestamp(asset.modificationDate),
                String(asset.pixelWidth),
                String(asset.pixelHeight),
                asset.isFavorite ? "1" : "0"
            ].joined(separator: ":")
        }
        .joined(separator: "|")

        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func timestamp(_ date: Date?) -> String {
        String(format: "%.3f", date?.timeIntervalSince1970 ?? 0)
    }
}

struct CachedPhotoFingerprint: Codable {
    let signature: String
    let fingerprint: String
}

actor DuplicateFingerprintCache {
    private struct Payload: Codable {
        let version: Int
        var fingerprints: [String: CachedPhotoFingerprint]
    }

    private let algorithmVersion = 1
    private let fileURL: URL
    private var fingerprints: [String: CachedPhotoFingerprint]?

    init() {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "DuplicateAnalysis",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("fingerprints.json")
    }

    func fingerprint(for id: String, signature: String) -> String? {
        loadIfNeeded()
        guard let cached = fingerprints?[id],
              cached.signature == signature else {
            return nil
        }
        return cached.fingerprint
    }

    func validFingerprints(for assets: [PHAsset]) -> [String: CachedPhotoFingerprint] {
        loadIfNeeded()
        guard let fingerprints else { return [:] }
        return Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
            let id = asset.localIdentifier
            let signature = PhotoFingerprintSignature.make(for: asset)
            guard let cached = fingerprints[id],
                  cached.signature == signature else {
                return nil
            }
            return (id, cached)
        })
    }

    func replace(with values: [String: CachedPhotoFingerprint]) throws {
        fingerprints = values
        let data = try JSONEncoder().encode(
            Payload(version: algorithmVersion, fingerprints: values)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        fingerprints = [:]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func sizeInBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ) else {
            return 0
        }
        return attributes[.size] as? Int64 ?? 0
    }

    private func loadIfNeeded() {
        guard fingerprints == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == algorithmVersion else {
            fingerprints = [:]
            return
        }
        fingerprints = payload.fingerprints
    }
}

enum PhotoFingerprintSignature {
    static func make(for asset: PHAsset) -> String {
        [
            asset.localIdentifier,
            String(format: "%.3f", asset.modificationDate?.timeIntervalSince1970 ?? 0),
            String(asset.pixelWidth),
            String(asset.pixelHeight)
        ].joined(separator: ":")
    }
}

actor MonthlyReviewStore {
    struct State: Codable {
        var reviewedIDs: Set<String>
        var markedIDs: Set<String>
    }

    private let fileURL: URL

    init() {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "MonthlyReview",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("progress.json")
    }

    func load() -> [String: State] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(
                [String: State].self,
                from: data
              ) else {
            return [:]
        }
        return stored
    }

    func save(_ states: [String: State]) throws {
        let data = try JSONEncoder().encode(states)
        try data.write(to: fileURL, options: .atomic)
    }
}

struct CachedMonthGroup: Codable {
    let id: String
    let date: Date
    let localIdentifiers: [String]
    let storageBytes: Int64
}

actor MonthlyAlbumsCache {
    private struct Payload: Codable {
        let version: Int
        let groups: [CachedMonthGroup]
    }

    private let algorithmVersion = 1
    private let fileURL: URL
    private var groups: [CachedMonthGroup]?

    init() {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "MonthlyAlbums",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("groups.json")
    }

    func load() -> [CachedMonthGroup]? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == algorithmVersion else {
            return nil
        }
        return payload.groups
    }

    func save(_ groups: [CachedMonthGroup]) throws {
        let data = try JSONEncoder().encode(
            Payload(version: algorithmVersion, groups: groups)
        )
        try data.write(to: fileURL, options: .atomic)
        self.groups = groups
    }

    func clear() throws {
        groups = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

struct CachedDetailGroupAsset: Codable {
    let id: String
    let signature: String
    let qualityScore: Double
    let isBest: Bool
}

struct CachedDetailGroup: Codable {
    let assets: [CachedDetailGroupAsset]
}

enum CachedDetailGroupAssetSignature {
    static func make(for asset: PHAsset) -> String {
        [
            asset.localIdentifier,
            String(format: "%.3f", asset.creationDate?.timeIntervalSince1970 ?? 0),
            String(format: "%.3f", asset.modificationDate?.timeIntervalSince1970 ?? 0),
            String(asset.pixelWidth),
            String(asset.pixelHeight),
            String(asset.mediaType.rawValue),
            String(asset.mediaSubtypes.rawValue),
            asset.isFavorite ? "1" : "0"
        ].joined(separator: ":")
    }
}

actor DetailGroupCache {
    private struct Payload: Codable {
        let version: Int
        let duplicateGroups: [CachedDetailGroup]
        let burstGroups: [CachedDetailGroup]
    }

    private let algorithmVersion = 1
    private let fileURL: URL
    private var payload: Payload?

    init() {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
        let directory = baseURL.appendingPathComponent(
            "DetailGroups",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("groups.json")
    }

    func loadDuplicateGroups() -> [CachedDetailGroup] {
        loadIfNeeded()
        return payload?.duplicateGroups ?? []
    }

    func loadBurstGroups() -> [CachedDetailGroup] {
        loadIfNeeded()
        return payload?.burstGroups ?? []
    }

    func saveDuplicateGroups(_ groups: [SimilarAssetGroup]) throws {
        loadIfNeeded()
        let nextPayload = Payload(
            version: algorithmVersion,
            duplicateGroups: groups.map(Self.cachedGroup),
            burstGroups: payload?.burstGroups ?? []
        )
        try save(nextPayload)
    }

    func saveBurstGroups(_ groups: [SimilarAssetGroup]) throws {
        loadIfNeeded()
        let nextPayload = Payload(
            version: algorithmVersion,
            duplicateGroups: payload?.duplicateGroups ?? [],
            burstGroups: groups.map(Self.cachedGroup)
        )
        try save(nextPayload)
    }

    func hasAnyCachedGroups() -> Bool {
        loadIfNeeded()
        return !(payload?.duplicateGroups.isEmpty ?? true) ||
            !(payload?.burstGroups.isEmpty ?? true)
    }

    func clear() throws {
        payload = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func sizeInBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ) else {
            return 0
        }
        return attributes[.size] as? Int64 ?? 0
    }

    private func loadIfNeeded() {
        guard payload == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Payload.self, from: data),
              stored.version == algorithmVersion else {
            payload = Payload(version: algorithmVersion, duplicateGroups: [], burstGroups: [])
            return
        }
        payload = stored
    }

    private func save(_ nextPayload: Payload) throws {
        let data = try JSONEncoder().encode(nextPayload)
        try data.write(to: fileURL, options: .atomic)
        payload = nextPayload
    }

    private static func cachedGroup(from group: SimilarAssetGroup) -> CachedDetailGroup {
        CachedDetailGroup(
            assets: group.assets.map { asset in
                CachedDetailGroupAsset(
                    id: asset.id,
                    signature: CachedDetailGroupAssetSignature.make(for: asset.asset),
                    qualityScore: asset.qualityScore,
                    isBest: asset.isBest
                )
            }
        )
    }
}
