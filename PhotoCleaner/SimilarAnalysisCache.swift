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
    var ocrText: String?
    var ocrIndexedAt: Date?
}

actor PhotoSearchIndexStore {
    private struct Payload: Codable {
        let version: Int
        var entries: [String: PhotoSearchIndexEntry]
    }

    static let shared = PhotoSearchIndexStore()

    private let algorithmVersion = 1
    private let fileURL: URL
    private var entries: [String: PhotoSearchIndexEntry]?

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
            let canReuseOCR = previous?.signature == signature
            updated[id] = Self.entry(
                for: asset,
                signature: signature,
                previousOCRText: canReuseOCR ? previous?.ocrText : nil,
                previousOCRIndexedAt: canReuseOCR ? previous?.ocrIndexedAt : nil
            )
        }

        // Drop deleted assets from the index.
        entries = updated.filter { activeIDs.contains($0.key) }
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

    func clear() throws {
        entries = [:]
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
        guard entries == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == algorithmVersion else {
            entries = [:]
            return
        }
        entries = payload.entries
    }

    private func save() throws {
        let data = try JSONEncoder().encode(
            Payload(version: algorithmVersion, entries: entries ?? [:])
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func upsertOCRText(_ text: String, for asset: PHAsset) {
        let signature = Self.signature(for: asset)
        var entry = Self.entry(
            for: asset,
            signature: signature,
            previousOCRText: text,
            previousOCRIndexedAt: Date()
        )
        entry.ocrText = text
        entry.ocrIndexedAt = Date()
        entries?[asset.localIdentifier] = entry
    }

    private static func entry(
        for asset: PHAsset,
        signature: String,
        previousOCRText: String?,
        previousOCRIndexedAt: Date?
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
            ocrText: previousOCRText,
            ocrIndexedAt: previousOCRIndexedAt
        )
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
