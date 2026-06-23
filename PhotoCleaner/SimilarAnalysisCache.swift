import CryptoKit
import Foundation
import Photos

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

    private let algorithmVersion = 2
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
