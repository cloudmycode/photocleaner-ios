import CoreGraphics
import CryptoKit
import AVFoundation
import Photos
import SwiftUI
import UIKit
import Vision

struct SimilarAsset: Identifiable, Hashable {
    let id: String
    let asset: PHAsset
    let qualityScore: Double
    let isBest: Bool

    static func == (lhs: SimilarAsset, rhs: SimilarAsset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct SimilarAssetGroup: Identifiable {
    let id: String
    let assets: [SimilarAsset]
    let creationDate: Date?
}

struct IdentifiablePHAsset: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

struct PhotoMonthGroup: Identifiable {
    let id: String
    let date: Date
    let assets: [PHAsset]
    let storageBytes: Int64
    let availableIDs: Set<String>

    init(
        id: String,
        date: Date,
        assets: [PHAsset],
        storageBytes: Int64
    ) {
        self.id = id
        self.date = date
        self.assets = assets
        self.storageBytes = storageBytes
        self.availableIDs = Set(assets.map(\.localIdentifier))
    }
}

private struct LibrarySnapshot {
    let imageAssets: [PHAsset]
    let videoAssets: [PHAsset]
    let screenshotAssets: [PHAsset]
    let largeVideoAssets: [PHAsset]
    let screenRecordingAssets: [PHAsset]
    let monthGroups: [PhotoMonthGroup]
    let burstCandidates: [[PHAsset]]
    let initialBurstGroups: [SimilarAssetGroup]
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let largeVideoStorageBytes: Int64
    let screenRecordingStorageBytes: Int64
    let initialBurstCandidateStorageBytes: Int64
    let emptyAlbumCount: Int
    let emptyAlbums: [(id: String, title: String)]
}

private struct HomeLibrarySummary: Codable {
    let photoCount: Int
    let videoCount: Int
    let screenshotCount: Int
    let largeVideoCount: Int
    let screenRecordingCount: Int
    let duplicateCandidateCount: Int
    let burstCandidateCount: Int
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let largeVideoStorageBytes: Int64
    let screenRecordingStorageBytes: Int64
    let duplicateCandidateStorageBytes: Int64
    let burstCandidateStorageBytes: Int64
    let emptyAlbumCount: Int
}

private struct LegacyHomeLibrarySummary: Codable {
    let photoCount: Int
    let videoCount: Int
    let screenshotCount: Int
    let largeVideoCount: Int
    let screenRecordingCount: Int
    let duplicateCandidateCount: Int
    let burstCandidateCount: Int
    let mediaStorageBytes: Int64
}

private struct MonthlyAlbumsCachePayload: Codable {
    let version: Int
    let groups: [CachedMonthGroup]
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {
    enum ScanState: Equatable {
        case idle
        case loadingLibrary
        case analyzing(current: Int, total: Int)
        case finished
        case failed
    }

    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var photoCount = 0
    @Published private(set) var videoCount = 0
    @Published private(set) var screenshotCount = 0
    @Published private(set) var screenshotAssets: [PHAsset] = []
    @Published private(set) var videoAssets: [PHAsset] = []
    @Published private(set) var largeVideoAssets: [PHAsset] = []
    @Published private(set) var screenRecordingAssets: [PHAsset] = []
    @Published private(set) var monthGroups: [PhotoMonthGroup] = []
    @Published private(set) var monthlyReviewedIDs: [String: Set<String>] = [:]
    @Published private(set) var monthlyMarkedIDs: [String: Set<String>] = [:]
    @Published private(set) var duplicateGroups: [SimilarAssetGroup] = []
    @Published private(set) var burstGroups: [SimilarAssetGroup] = []
    @Published private(set) var duplicateScanProgress: (current: Int, total: Int)?
    @Published private(set) var hasDuplicateScanResults = false
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var analysisCacheSize: Int64 = 0
    @Published private(set) var hasCompletedInitialAnalysis = false
    @Published private(set) var mediaStorageBytes: Int64 = 0
    @Published private(set) var hasHomeSummary = false
    @Published private(set) var isUsingCachedHomeSummary = false
    @Published private(set) var largeVideoCount = 0
    @Published private(set) var screenRecordingCount = 0
    @Published private(set) var duplicateCandidateCount = 0
    @Published private(set) var burstCandidateCount = 0
    @Published private(set) var videoStorageBytes: Int64 = 0
    @Published private(set) var screenshotStorageBytes: Int64 = 0
    @Published private(set) var largeVideoStorageBytes: Int64 = 0
    @Published private(set) var screenRecordingStorageBytes: Int64 = 0
    @Published private(set) var duplicateCandidateStorageBytes: Int64 = 0
    @Published private(set) var burstCandidateStorageBytes: Int64 = 0
    @Published private(set) var emptyAlbumCount = 0
    @Published private(set) var emptyAlbums: [(id: String, title: String)] = []
    @Published private(set) var monthlyProgress: [String: Double] = [:]
    @Published private(set) var monthlyReviewedCounts: [String: Int] = [:]

    let imageManager = PHCachingImageManager()

    nonisolated private static let homeSummaryKey = "photoCleaner.homeLibrarySummary.v1"
    nonisolated private static let initialAnalysisCompleteKey = "photoCleaner.initialAnalysisComplete.v1"
    nonisolated private static let fallbackShotInterval: TimeInterval = 3
    nonisolated private static let fallbackSequenceDuration: TimeInterval = 10
    private let analysisCache = SimilarAnalysisCache()
    private let duplicateCache = DuplicateFingerprintCache()
    private let monthlyReviewStore = MonthlyReviewStore()
    private let monthlyAlbumsCache = MonthlyAlbumsCache()
    private var scanTask: Task<Void, Never>?
    private var libraryChangeDebounce: Task<Void, Never>?

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        restoreHomeSummary()
        hasCompletedInitialAnalysis = hasHomeSummary &&
            UserDefaults.standard.bool(forKey: Self.initialAnalysisCompleteKey)
        restoreMonthlyAlbumsFromCache()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func start() {
        Task {
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorizationStatus == .notDetermined {
                authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                scanState = .idle
                return
            }
            refreshLibrary()
        }
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func restoreHomeSummary() {
        guard let data = UserDefaults.standard.data(forKey: Self.homeSummaryKey) else {
            return
        }
        if let summary = try? JSONDecoder().decode(HomeLibrarySummary.self, from: data) {
            applyHomeSummary(summary)
            return
        }
        if let summary = try? JSONDecoder().decode(LegacyHomeLibrarySummary.self, from: data) {
            photoCount = summary.photoCount
            videoCount = summary.videoCount
            screenshotCount = summary.screenshotCount
            largeVideoCount = summary.largeVideoCount
            screenRecordingCount = summary.screenRecordingCount
            duplicateCandidateCount = summary.duplicateCandidateCount
            burstCandidateCount = summary.burstCandidateCount
            mediaStorageBytes = summary.mediaStorageBytes
            hasHomeSummary = true
            isUsingCachedHomeSummary = true
        }
    }

    private func restoreMonthlyAlbumsFromCache() {
        let fileURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("MonthlyAlbums", isDirectory: true)
            .appendingPathComponent("groups.json")
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(MonthlyAlbumsCachePayload.self, from: data),
              payload.version == 1 else {
            return
        }
        let groups: [PhotoMonthGroup] = payload.groups.compactMap { cached in
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "localIdentifier IN %@",
                cached.localIdentifiers
            )
            let result = PHAsset.fetchAssets(with: .image, options: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            guard !assets.isEmpty else { return nil }
            return PhotoMonthGroup(
                id: cached.id,
                date: cached.date,
                assets: assets.sorted {
                    ($0.creationDate ?? .distantPast) >
                        ($1.creationDate ?? .distantPast)
                },
                storageBytes: cached.storageBytes
            )
        }
        if !groups.isEmpty {
            monthGroups = groups
            rebuildAllMonthlyProgress()
        }
    }

    private func applyHomeSummary(_ summary: HomeLibrarySummary) {
        photoCount = summary.photoCount
        videoCount = summary.videoCount
        screenshotCount = summary.screenshotCount
        largeVideoCount = summary.largeVideoCount
        screenRecordingCount = summary.screenRecordingCount
        duplicateCandidateCount = summary.duplicateCandidateCount
        burstCandidateCount = summary.burstCandidateCount
        mediaStorageBytes = summary.mediaStorageBytes
        videoStorageBytes = summary.videoStorageBytes
        screenshotStorageBytes = summary.screenshotStorageBytes
        largeVideoStorageBytes = summary.largeVideoStorageBytes
        screenRecordingStorageBytes = summary.screenRecordingStorageBytes
        duplicateCandidateStorageBytes = summary.duplicateCandidateStorageBytes
        burstCandidateStorageBytes = summary.burstCandidateStorageBytes
        emptyAlbumCount = summary.emptyAlbumCount
        hasHomeSummary = true
        isUsingCachedHomeSummary = true
    }

    private func persistHomeSummary() {
        let summary = HomeLibrarySummary(
            photoCount: photoCount,
            videoCount: videoCount,
            screenshotCount: screenshotCount,
            largeVideoCount: largeVideoCount,
            screenRecordingCount: screenRecordingCount,
            duplicateCandidateCount: duplicateCandidateCount,
            burstCandidateCount: burstCandidateCount,
            mediaStorageBytes: mediaStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            largeVideoStorageBytes: largeVideoStorageBytes,
            screenRecordingStorageBytes: screenRecordingStorageBytes,
            duplicateCandidateStorageBytes: duplicateCandidateStorageBytes,
            burstCandidateStorageBytes: burstCandidateStorageBytes,
            emptyAlbumCount: emptyAlbumCount
        )
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: Self.homeSummaryKey)
        hasHomeSummary = true
    }

    func refreshLibrary() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            scanState = .loadingLibrary
            if !hasHomeSummary {
                photoCount = 0
                videoCount = 0
                screenshotCount = 0
                largeVideoCount = 0
                screenRecordingCount = 0
                duplicateCandidateCount = 0
                burstCandidateCount = 0
                mediaStorageBytes = 0
                videoStorageBytes = 0
                screenshotStorageBytes = 0
                largeVideoStorageBytes = 0
                screenRecordingStorageBytes = 0
                duplicateCandidateStorageBytes = 0
                burstCandidateStorageBytes = 0
                emptyAlbumCount = 0
                emptyAlbums = []
            }
            duplicateScanProgress = nil

            let snapshot = await Task.detached(priority: .utility) {
                Self.makeLibrarySnapshot()
            }.value
            guard !Task.isCancelled else { return }

            photoCount = snapshot.imageAssets.count
            videoCount = snapshot.videoAssets.count
            screenshotAssets = snapshot.screenshotAssets
            screenshotCount = snapshot.screenshotAssets.count
            videoAssets = snapshot.videoAssets
            largeVideoAssets = snapshot.largeVideoAssets
            largeVideoCount = snapshot.largeVideoAssets.count
            screenRecordingAssets = snapshot.screenRecordingAssets
            screenRecordingCount = snapshot.screenRecordingAssets.count
            monthGroups = snapshot.monthGroups
            persistMonthlyAlbums(from: snapshot.monthGroups)
            rebuildAllMonthlyProgress()
            burstGroups = snapshot.initialBurstGroups
            burstCandidateCount = Self.cleanableCount(in: snapshot.initialBurstGroups)
            burstCandidateStorageBytes = snapshot.initialBurstCandidateStorageBytes
            mediaStorageBytes = snapshot.mediaStorageBytes
            videoStorageBytes = snapshot.videoStorageBytes
            screenshotStorageBytes = snapshot.screenshotStorageBytes
            largeVideoStorageBytes = snapshot.largeVideoStorageBytes
            screenRecordingStorageBytes = snapshot.screenRecordingStorageBytes
            emptyAlbumCount = snapshot.emptyAlbumCount
            emptyAlbums = snapshot.emptyAlbums
            persistHomeSummary()

            await restoreMonthlyReviewProgress()
            await Task.yield()

            let duplicateCacheComplete = await restoreDuplicateGroupsFromCache(
                in: snapshot.imageAssets
            )
            persistHomeSummary()
            if !duplicateCacheComplete {
                await scanDuplicates(in: snapshot.imageAssets)
                persistHomeSummary()
            }

            var analyzedBurstGroups = snapshot.initialBurstGroups
            let candidates = snapshot.burstCandidates
            scanState = .analyzing(current: 0, total: candidates.count)

            var activeCache: [String: CachedSimilarGroup] = [:]
            for (index, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                let signature = SimilarAnalysisSignature.make(for: candidate)
                let cached = await analysisCache.group(for: signature)
                let group: SimilarAssetGroup?

                if let cached {
                    activeCache[signature] = cached
                    group = Self.restoreGroup(cached, from: candidate)
                } else {
                    group = await analyzeBurstGroup(candidate)
                    activeCache[signature] = Self.cacheGroup(
                        group,
                        signature: signature
                    )
                }

                if let group {
                    if let groupIndex = analyzedBurstGroups.firstIndex(where: { $0.id == group.id }) {
                        analyzedBurstGroups[groupIndex] = group
                    } else {
                        analyzedBurstGroups.append(group)
                    }
                    burstGroups = analyzedBurstGroups.sorted {
                        ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                    }
                    burstCandidateCount = Self.cleanableCount(in: burstGroups)
                    burstCandidateStorageBytes = Self.cleanableStorageBytes(in: burstGroups)
                }
                scanState = .analyzing(current: index + 1, total: candidates.count)
                await Task.yield()
            }
            try? await analysisCache.replace(with: activeCache)
            analysisCacheSize = await analysisCache.sizeInBytes() +
                duplicateCache.sizeInBytes()
            persistHomeSummary()
            markInitialAnalysisComplete()
            scanState = .finished
        }
    }

    func requestThumbnail(
        for asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID {
        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return imageManager.requestImage(
            for: asset,
            targetSize: pixelSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
            if !cancelled {
                completion(image)
            }
        }
    }

    func cancelImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    func requestPlayerItem(
        for asset: PHAsset,
        completion: @escaping (AVPlayerItem?) -> Void
    ) -> PHImageRequestID {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.version = .current
        options.isNetworkAccessAllowed = true

        return imageManager.requestPlayerItem(
            forVideo: asset,
            options: options
        ) { playerItem, _ in
            completion(playerItem)
        }
    }

    func requestLivePhoto(
        for asset: PHAsset,
        targetSize: CGSize,
        completion: @escaping (PHLivePhoto?) -> Void
    ) -> PHImageRequestID {
        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true

        return imageManager.requestLivePhoto(
            for: asset,
            targetSize: pixelSize,
            contentMode: .aspectFit,
            options: options
        ) { livePhoto, info in
            let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
            if !cancelled {
                completion(livePhoto)
            }
        }
    }

    nonisolated func storageBytes(for asset: PHAsset) -> Int64 {
        Self.assetStorageBytes(asset)
    }

    func deleteEmptyAlbum(with localIdentifier: String) async throws {
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard collections.firstObject != nil else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections(collections)
        }
        refreshLibrary()
    }

    func deleteAssets(with identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(result)
        }
        refreshLibrary()
    }

    func setFavorite(_ isFavorite: Bool, for asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = isFavorite
        }
    }

    func reviewedIDs(for monthID: String) -> Set<String> {
        monthlyReviewedIDs[monthID] ?? []
    }

    func markedIDs(for monthID: String) -> Set<String> {
        monthlyMarkedIDs[monthID] ?? []
    }

    func monthlyProgress(for group: PhotoMonthGroup) -> Double {
        if let cached = monthlyProgress[group.id] { return cached }
        guard !group.assets.isEmpty else { return 1 }
        let reviewed = reviewedIDs(for: group.id).intersection(group.availableIDs)
        return Double(reviewed.count) / Double(group.availableIDs.count)
    }

    func monthlyReviewedCount(for group: PhotoMonthGroup) -> Int {
        if let cached = monthlyReviewedCounts[group.id] { return cached }
        return reviewedIDs(for: group.id).intersection(group.availableIDs).count
    }

    func setMonthlyAsset(
        _ assetID: String,
        reviewed: Bool,
        markedForDeletion: Bool = false,
        monthID: String
    ) {
        var reviewedIDs = monthlyReviewedIDs[monthID] ?? []
        var markedIDs = monthlyMarkedIDs[monthID] ?? []
        if reviewed {
            reviewedIDs.insert(assetID)
            if markedForDeletion {
                markedIDs.insert(assetID)
            } else {
                markedIDs.remove(assetID)
            }
        } else {
            reviewedIDs.remove(assetID)
            markedIDs.remove(assetID)
        }
        monthlyReviewedIDs[monthID] = reviewedIDs
        monthlyMarkedIDs[monthID] = markedIDs
        persistMonthlyReviewProgress()
        rebuildMonthlyProgress(for: monthID)
    }

    private func rebuildMonthlyProgress(for monthID: String) {
        guard let group = monthGroups.first(where: { $0.id == monthID }) else {
            monthlyProgress.removeValue(forKey: monthID)
            monthlyReviewedCounts.removeValue(forKey: monthID)
            return
        }
        let reviewed = reviewedIDs(for: monthID).intersection(group.availableIDs)
        monthlyReviewedCounts[monthID] = reviewed.count
        monthlyProgress[monthID] = group.assets.isEmpty
            ? 1
            : Double(reviewed.count) / Double(group.availableIDs.count)
    }

    private func rebuildAllMonthlyProgress() {
        var progress: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for group in monthGroups {
            let reviewed = reviewedIDs(for: group.id).intersection(group.availableIDs)
            counts[group.id] = reviewed.count
            progress[group.id] = group.assets.isEmpty
                ? 1
                : Double(reviewed.count) / Double(group.availableIDs.count)
        }
        monthlyProgress = progress
        monthlyReviewedCounts = counts
    }

    func clearAnalysisCache() {
        scanTask?.cancel()
        hasCompletedInitialAnalysis = false
        UserDefaults.standard.removeObject(forKey: Self.initialAnalysisCompleteKey)
        Task {
            try? await analysisCache.clear()
            try? await duplicateCache.clear()
            try? await monthlyAlbumsCache.clear()
            analysisCacheSize = 0
            scanState = .idle
        }
    }

    private func markInitialAnalysisComplete() {
        hasCompletedInitialAnalysis = true
        UserDefaults.standard.set(true, forKey: Self.initialAnalysisCompleteKey)
    }

    private func restoreMonthlyReviewProgress() async {
        let stored = await monthlyReviewStore.load()
        var reconciledReviewed: [String: Set<String>] = [:]
        var reconciledMarked: [String: Set<String>] = [:]
        for group in monthGroups {
            let availableIDs = Set(group.assets.map(\.localIdentifier))
            let reviewed = (stored[group.id]?.reviewedIDs ?? [])
                .intersection(availableIDs)
            let marked = (stored[group.id]?.markedIDs ?? [])
                .intersection(availableIDs)
            if !reviewed.isEmpty {
                reconciledReviewed[group.id] = reviewed
            }
            if !marked.isEmpty {
                reconciledMarked[group.id] = marked
            }
        }
        monthlyReviewedIDs = reconciledReviewed
        monthlyMarkedIDs = reconciledMarked
        try? await monthlyReviewStore.save(monthlyReviewStates())
    }

    private func persistMonthlyReviewProgress() {
        let snapshot = monthlyReviewStates()
        Task {
            try? await monthlyReviewStore.save(snapshot)
        }
    }

    private func persistMonthlyAlbums(from groups: [PhotoMonthGroup]) {
        let cached = groups.map { group in
            CachedMonthGroup(
                id: group.id,
                date: group.date,
                localIdentifiers: group.assets.map(\.localIdentifier),
                storageBytes: group.storageBytes
            )
        }
        Task {
            try? await monthlyAlbumsCache.save(cached)
        }
    }

    private func monthlyReviewStates() -> [String: MonthlyReviewStore.State] {
        let monthIDs = Set(monthlyReviewedIDs.keys)
            .union(monthlyMarkedIDs.keys)
        return Dictionary(uniqueKeysWithValues: monthIDs.map { monthID in
            (
                monthID,
                MonthlyReviewStore.State(
                    reviewedIDs: monthlyReviewedIDs[monthID] ?? [],
                    markedIDs: monthlyMarkedIDs[monthID] ?? []
                )
            )
        })
    }

    private func restoreDuplicateGroupsFromCache(in assets: [PHAsset]) async -> Bool {
        let cached = await duplicateCache.validFingerprints(for: assets)
        guard !cached.isEmpty else {
            hasDuplicateScanResults = false
            return assets.isEmpty
        }

        applyDuplicateGroups(
            Self.makeDuplicateGroups(
                from: assets,
                fingerprints: cached.mapValues(\.fingerprint)
            )
        )
        return cached.count == assets.count
    }

    private func scanDuplicates(in assets: [PHAsset]) async {
        duplicateScanProgress = (0, assets.count)
        var activeCache: [String: CachedPhotoFingerprint] = [:]
        var assetsByFingerprint: [String: [PHAsset]] = [:]

        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { return }
            let signature = PhotoFingerprintSignature.make(for: asset)
            let id = asset.localIdentifier
            let fingerprint: String?

            if let cached = await duplicateCache.fingerprint(
                for: id,
                signature: signature
            ) {
                fingerprint = cached
            } else if let image = await requestFingerprintImage(for: asset) {
                fingerprint = await Task.detached(priority: .utility) {
                    Self.duplicateFingerprint(for: image)
                }.value
            } else {
                fingerprint = nil
            }

            if let fingerprint {
                activeCache[id] = CachedPhotoFingerprint(
                    signature: signature,
                    fingerprint: fingerprint
                )
                let aspectBucket = Self.aspectBucket(for: asset)
                assetsByFingerprint["\(aspectBucket):\(fingerprint)", default: []]
                    .append(asset)
            }
            duplicateScanProgress = (index + 1, assets.count)
            if index.isMultiple(of: 20) {
                await Task.yield()
            }
        }

        applyDuplicateGroups(
            assetsByFingerprint.values
                .filter { $0.count >= 2 }
                .map(Self.makeDuplicateGroup)
                .sorted {
                    ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                }
        )
        try? await duplicateCache.replace(with: activeCache)
        duplicateScanProgress = nil
    }

    private func applyDuplicateGroups(_ groups: [SimilarAssetGroup]) {
        duplicateGroups = groups
        duplicateCandidateCount = Self.cleanableCount(in: groups)
        duplicateCandidateStorageBytes = Self.cleanableStorageBytes(in: groups)
        hasDuplicateScanResults = true
    }

    nonisolated private static func makeDuplicateGroups(
        from assets: [PHAsset],
        fingerprints: [String: String]
    ) -> [SimilarAssetGroup] {
        var assetsByFingerprint: [String: [PHAsset]] = [:]
        for asset in assets {
            guard let fingerprint = fingerprints[asset.localIdentifier] else { continue }
            let aspectBucket = aspectBucket(for: asset)
            assetsByFingerprint["\(aspectBucket):\(fingerprint)", default: []].append(asset)
        }
        return assetsByFingerprint.values
            .filter { $0.count >= 2 }
            .map(makeDuplicateGroup)
            .sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
    }

    nonisolated private static func cleanableCount(in groups: [SimilarAssetGroup]) -> Int {
        groups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
    }

    nonisolated private static func cleanableStorageBytes(in groups: [SimilarAssetGroup]) -> Int64 {
        groups.reduce(Int64(0)) { total, group in
            total + group.assets
                .filter { !$0.isBest }
                .reduce(Int64(0)) { $0 + assetStorageBytes($1.asset) }
        }
    }

    nonisolated private static func cleanableStorageBytes(
        in groups: [SimilarAssetGroup],
        storageByID: [String: Int64]
    ) -> Int64 {
        groups.reduce(Int64(0)) { total, group in
            total + group.assets
                .filter { !$0.isBest }
                .reduce(Int64(0)) { $0 + (storageByID[$1.id] ?? 0) }
        }
    }

    private func analyzeBurstGroup(_ assets: [PHAsset]) async -> SimilarAssetGroup? {
        let similarAssets = await visuallySimilarBurstAssets(from: assets)
        guard similarAssets.count >= 2 else { return nil }

        var analyzed: [AnalyzedAsset] = []

        for asset in similarAssets {
            guard !Task.isCancelled,
                  let image = await requestAnalysisImage(for: asset),
                  let cgImage = image.cgImage else {
                continue
            }

            if let result = await Task.detached(priority: .utility, operation: { () -> AnalyzedAsset? in
                return AnalyzedAsset(
                    asset: asset,
                    qualityScore: Self.qualityScore(for: cgImage, asset: asset)
                )
            }).value {
                analyzed.append(result)
            }
        }

        guard analyzed.count >= 2 else { return nil }
        let analyzedByID = Dictionary(
            uniqueKeysWithValues: analyzed.map { ($0.asset.localIdentifier, $0) }
        )
        let bestID = analyzed.max(by: { $0.qualityScore < $1.qualityScore })?
            .asset.localIdentifier
        let results = similarAssets.sorted(by: Self.assetDateAscending).map { asset in
            let qualityScore = analyzedByID[asset.localIdentifier]?.qualityScore ??
                Self.qualityScore(forMetadata: asset)
            return SimilarAsset(
                id: asset.localIdentifier,
                asset: asset,
                qualityScore: qualityScore,
                isBest: asset.localIdentifier == bestID
            )
        }

        return SimilarAssetGroup(
            id: results.map(\.id).sorted().joined(separator: "|"),
            assets: results,
            creationDate: results.compactMap(\.asset.creationDate).min()
        )
    }

    private func visuallySimilarBurstAssets(from assets: [PHAsset]) async -> [PHAsset] {
        var hashed: [(asset: PHAsset, hash: UInt64)] = []
        for asset in assets.sorted(by: Self.assetDateAscending) {
            guard !Task.isCancelled,
                  let image = await requestFingerprintImage(for: asset) else {
                continue
            }
            hashed.append((asset, Self.averageHash(for: image)))
        }
        guard hashed.count >= 2 else { return [] }

        var runs: [[(asset: PHAsset, hash: UInt64)]] = []
        var current: [(asset: PHAsset, hash: UInt64)] = [hashed[0]]
        for item in hashed.dropFirst() {
            if let previous = current.last,
               Self.areVisuallySimilar(previous.asset, item.asset),
               Self.hammingDistance(previous.hash, item.hash) <= 14 {
                current.append(item)
            } else {
                if current.count >= 2 {
                    runs.append(current)
                }
                current = [item]
            }
        }
        if current.count >= 2 {
            runs.append(current)
        }

        return runs
            .max {
                if $0.count == $1.count {
                    return ($0.first?.asset.creationDate ?? .distantPast) <
                        ($1.first?.asset.creationDate ?? .distantPast)
                }
                return $0.count < $1.count
            }?
            .map(\.asset) ?? []
    }

    private func requestAnalysisImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false

            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 256, height: 256),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                guard !resumed, !degraded else { return }
                resumed = true
                continuation.resume(returning: cancelled ? nil : image)
            }
        }
    }

    private func requestFingerprintImage(for asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false

            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                guard !resumed, !degraded else { return }
                resumed = true
                continuation.resume(returning: cancelled ? nil : image?.cgImage)
            }
        }
    }

    nonisolated private static func fetchImageAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    nonisolated private static func fetchCount(mediaType: PHAssetMediaType) -> Int {
        PHAsset.fetchAssets(with: mediaType, options: nil).count
    }

    nonisolated private static func fetchVideoAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    nonisolated private static func fetchEmptyAlbums() -> [(id: String, title: String)] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var result: [(id: String, title: String)] = []
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count == 0 {
                result.append((collection.localIdentifier, collection.localizedTitle ?? "-"))
            }
        }
        return result
    }

    nonisolated private static func makeLibrarySnapshot() -> LibrarySnapshot {
        let imageAssets = fetchImageAssets()
        let videos = fetchVideoAssets()
        let imageStorageByID = storageMap(for: imageAssets)
        let videoStorageByID = storageMap(for: videos)
        let screenshotAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoScreenshot) }
                .reversed()
        )
        let videoAssets = Array(videos.reversed())
        let largeVideoAssets = Array(
            videos
                .filter { $0.duration >= 60 }
                .reversed()
        )
        let screenRecordingAssets = Array(
            videos
                .filter { $0.mediaSubtypes.contains(.videoScreenRecording) }
                .reversed()
        )
        let monthGroups = makeMonthGroups(
            from: imageAssets,
            storageByID: imageStorageByID
        )
        let burstCandidates = continuousShotCandidateGroups(
            assets: imageAssets,
            maximumAdjacentInterval: fallbackShotInterval,
            maximumSequenceDuration: fallbackSequenceDuration
        )
        let initialBurstGroups: [SimilarAssetGroup] = []
        let imageStorageBytes = imageStorageByID.values.reduce(Int64(0), +)
        let videoStorageBytes = videoStorageByID.values.reduce(Int64(0), +)
        let screenshotStorageBytes = storageBytes(
            for: screenshotAssets,
            storageByID: imageStorageByID
        )
        let largeVideoStorageBytes = storageBytes(
            for: largeVideoAssets,
            storageByID: videoStorageByID
        )
        let screenRecordingStorageBytes = storageBytes(
            for: screenRecordingAssets,
            storageByID: videoStorageByID
        )
        let burstCandidateStorageBytes = cleanableStorageBytes(
            in: initialBurstGroups,
            storageByID: imageStorageByID
        )
        let emptyAlbums = fetchEmptyAlbums()

        return LibrarySnapshot(
            imageAssets: imageAssets,
            videoAssets: videoAssets,
            screenshotAssets: screenshotAssets,
            largeVideoAssets: largeVideoAssets,
            screenRecordingAssets: screenRecordingAssets,
            monthGroups: monthGroups,
            burstCandidates: burstCandidates,
            initialBurstGroups: initialBurstGroups,
            mediaStorageBytes: imageStorageBytes + videoStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            largeVideoStorageBytes: largeVideoStorageBytes,
            screenRecordingStorageBytes: screenRecordingStorageBytes,
            initialBurstCandidateStorageBytes: burstCandidateStorageBytes,
            emptyAlbumCount: emptyAlbums.count,
            emptyAlbums: emptyAlbums
        )
    }

    nonisolated private static func storageMap(for assets: [PHAsset]) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: assets.map {
            ($0.localIdentifier, assetStorageBytes($0))
        })
    }

    nonisolated private static func storageBytes(
        for assets: [PHAsset],
        storageByID: [String: Int64]
    ) -> Int64 {
        assets.reduce(Int64(0)) { $0 + (storageByID[$1.localIdentifier] ?? 0) }
    }

    nonisolated private static func assetStorageBytes(_ asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { total, resource in
            if let fileSize = resource.value(forKey: "fileSize") as? NSNumber {
                return total + fileSize.int64Value
            }
            return total
        }
    }

    nonisolated private static func makeMonthGroups(
        from assets: [PHAsset],
        storageByID: [String: Int64]
    ) -> [PhotoMonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: assets) { asset in
            calendar.date(
                from: calendar.dateComponents([.year, .month], from: asset.creationDate ?? .distantPast)
            ) ?? .distantPast
        }
        return grouped
            .map { date, assets in
                PhotoMonthGroup(
                    id: String(date.timeIntervalSince1970),
                    date: date,
                    assets: Array(assets.reversed()),
                    storageBytes: storageBytes(for: assets, storageByID: storageByID)
                )
            }
            .sorted { $0.date > $1.date }
    }

    nonisolated private static func duplicateFingerprint(for image: CGImage) -> String? {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let quantized = pixels.map { $0 & 0xF0 }
        return SHA256.hash(data: Data(quantized))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func aspectBucket(for asset: PHAsset) -> Int {
        guard asset.pixelHeight > 0 else { return 0 }
        return Int((Double(asset.pixelWidth) / Double(asset.pixelHeight) * 1000).rounded())
    }

    nonisolated private static func areVisuallySimilar(_ left: PHAsset, _ right: PHAsset) -> Bool {
        abs(aspectBucket(for: left) - aspectBucket(for: right)) <= 20
    }

    nonisolated private static func averageHash(for image: CGImage) -> UInt64 {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let average = pixels.reduce(0) { $0 + Int($1) } / max(pixels.count, 1)
        return pixels.enumerated().reduce(UInt64(0)) { result, item in
            item.element >= average
                ? result | (UInt64(1) << UInt64(item.offset))
                : result
        }
    }

    nonisolated private static func hammingDistance(_ left: UInt64, _ right: UInt64) -> Int {
        (left ^ right).nonzeroBitCount
    }

    nonisolated private static func makeDuplicateGroup(_ assets: [PHAsset]) -> SimilarAssetGroup {
        let sorted = assets.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        let keepID = sorted.first(where: \.isFavorite)?.localIdentifier ??
            sorted.first?.localIdentifier
        let results = sorted.map {
            SimilarAsset(
                id: $0.localIdentifier,
                asset: $0,
                qualityScore: 0,
                isBest: $0.localIdentifier == keepID
            )
        }
        return SimilarAssetGroup(
            id: results.map(\.id).sorted().joined(separator: "|"),
            assets: results,
            creationDate: sorted.first?.creationDate
        )
    }

    nonisolated private static func makeBurstGroup(_ assets: [PHAsset]) -> SimilarAssetGroup {
        let sorted = assets.sorted(by: assetDateAscending)
        let keepID = sorted.first(where: \.isFavorite)?.localIdentifier ??
            sorted.max(by: { qualityScore(forMetadata: $0) < qualityScore(forMetadata: $1) })?
                .localIdentifier
        let results = sorted.map {
            SimilarAsset(
                id: $0.localIdentifier,
                asset: $0,
                qualityScore: qualityScore(forMetadata: $0),
                isBest: $0.localIdentifier == keepID
            )
        }
        return SimilarAssetGroup(
            id: results.map(\.id).sorted().joined(separator: "|"),
            assets: results,
            creationDate: sorted.first?.creationDate
        )
    }

    nonisolated private static func restoreGroup(
        _ cached: CachedSimilarGroup,
        from assets: [PHAsset]
    ) -> SimilarAssetGroup? {
        guard cached.assets.count >= 2 else { return nil }
        let assetsByID = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) }
        )
        let restored = cached.assets.compactMap { item -> SimilarAsset? in
            guard let asset = assetsByID[item.id] else { return nil }
            return SimilarAsset(
                id: item.id,
                asset: asset,
                qualityScore: item.qualityScore,
                isBest: item.isBest
            )
        }
        guard restored.count == cached.assets.count else { return nil }
        return SimilarAssetGroup(
            id: restored.map(\.id).sorted().joined(separator: "|"),
            assets: restored,
            creationDate: restored.compactMap(\.asset.creationDate).min()
        )
    }

    nonisolated private static func cacheGroup(
        _ group: SimilarAssetGroup?,
        signature: String
    ) -> CachedSimilarGroup {
        CachedSimilarGroup(
            signature: signature,
            assets: group?.assets.map {
                CachedSimilarAsset(
                    id: $0.id,
                    qualityScore: $0.qualityScore,
                    isBest: $0.isBest
                )
            } ?? []
        )
    }

    nonisolated private static func continuousShotCandidateGroups(
        assets: [PHAsset],
        maximumAdjacentInterval: TimeInterval,
        maximumSequenceDuration: TimeInterval
    ) -> [[PHAsset]] {
        let burstGroups = Dictionary(
            grouping: assets.compactMap { asset -> (String, PHAsset)? in
                guard let identifier = asset.burstIdentifier else { return nil }
                return (identifier, asset)
            },
            by: \.0
        )
        .values
        .map { $0.map(\.1).sorted(by: assetDateAscending) }
        .filter { $0.count >= 2 }

        let burstAssetIDs = Set(
            burstGroups.flatMap { $0.map(\.localIdentifier) }
        )
        let fallbackAssets = assets.filter {
            !burstAssetIDs.contains($0.localIdentifier)
        }

        var fallbackGroups: [[PHAsset]] = []
        var current: [PHAsset] = []

        for asset in fallbackAssets {
            guard let date = asset.creationDate else { continue }
            let previousDate = current.last?.creationDate
            let firstDate = current.first?.creationDate
            let isAdjacent = previousDate.map {
                date.timeIntervalSince($0) <= maximumAdjacentInterval
            } ?? false
            let isShortSequence = firstDate.map {
                date.timeIntervalSince($0) <= maximumSequenceDuration
            } ?? false
            let hasMatchingShape = current.last.map {
                aspectBucket(for: $0) == aspectBucket(for: asset)
            } ?? false

            if isAdjacent && isShortSequence && hasMatchingShape {
                current.append(asset)
            } else {
                if current.count >= 2 {
                    fallbackGroups.append(current)
                }
                current = [asset]
            }
        }
        if current.count >= 2 {
            fallbackGroups.append(current)
        }
        return (burstGroups + fallbackGroups).sorted {
            ($0.first?.creationDate ?? .distantPast) <
                ($1.first?.creationDate ?? .distantPast)
        }
    }

    nonisolated private static func assetDateAscending(
        _ left: PHAsset,
        _ right: PHAsset
    ) -> Bool {
        (left.creationDate ?? .distantPast) <
            (right.creationDate ?? .distantPast)
    }

    nonisolated private static func qualityScore(for image: CGImage, asset: PHAsset) -> Double {
        let sharpness = edgeEnergy(for: image)
        let resolution = log2(Double(max(asset.pixelWidth * asset.pixelHeight, 1))) / 30
        let faceQuality = faceCaptureQuality(for: image) ?? sharpness
        let favoriteBonus = asset.isFavorite ? 0.08 : 0
        return sharpness * 0.58 + faceQuality * 0.24 + resolution * 0.18 + favoriteBonus
    }

    nonisolated private static func qualityScore(forMetadata asset: PHAsset) -> Double {
        let resolution = log2(Double(max(asset.pixelWidth * asset.pixelHeight, 1))) / 30
        let favoriteBonus = asset.isFavorite ? 0.2 : 0
        return resolution + favoriteBonus
    }

    nonisolated private static func faceCaptureQuality(for image: CGImage) -> Double? {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])
        return request.results?
            .compactMap(\.faceCaptureQuality)
            .map(Double.init)
            .max()
    }

    nonisolated private static func edgeEnergy(for image: CGImage) -> Double {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        var samples = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let horizontal = abs(Int(pixels[index - 1]) - Int(pixels[index + 1]))
                let vertical = abs(Int(pixels[index - width]) - Int(pixels[index + width]))
                total += Double(horizontal + vertical)
                samples += 1
            }
        }
        return min(total / Double(max(samples, 1)) / 64, 1)
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.libraryChangeDebounce?.cancel()
            self.libraryChangeDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshLibrary()
            }
        }
    }
}

private struct AnalyzedAsset {
    let asset: PHAsset
    let qualityScore: Double
}

struct PhotoThumbnailView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let asset: PHAsset
    let targetSize: CGSize

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipped()
        .onAppear {
            guard image == nil else { return }
            requestID = library.requestThumbnail(for: asset, targetSize: targetSize) {
                image = $0
            }
        }
        .onDisappear {
            if let requestID {
                library.cancelImageRequest(requestID)
            }
        }
    }
}
