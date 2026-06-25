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
    let livePhotoAssets: [PHAsset]
    let largeVideoAssets: [PHAsset]
    let screenRecordingAssets: [PHAsset]
    let monthGroups: [PhotoMonthGroup]
    let burstCandidates: [[PHAsset]]
    let initialBurstGroups: [SimilarAssetGroup]
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let livePhotoStorageBytes: Int64
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
    let livePhotoCount: Int?
    let largeVideoCount: Int
    let screenRecordingCount: Int
    let duplicateCandidateCount: Int
    let burstCandidateCount: Int
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let livePhotoStorageBytes: Int64?
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

private struct MediaAssetSnapshot {
    let screenshotAssets: [PHAsset]
    let livePhotoAssets: [PHAsset]
    let videoAssets: [PHAsset]
    let largeVideoAssets: [PHAsset]
    let screenRecordingAssets: [PHAsset]
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let livePhotoStorageBytes: Int64
    let largeVideoStorageBytes: Int64
    let screenRecordingStorageBytes: Int64
}

@MainActor
final class PhotoLibraryService: NSObject, ObservableObject {
    enum SmartSearchDebugExportError: LocalizedError {
        case photoAccessRequired

        var errorDescription: String? {
            switch self {
            case .photoAccessRequired:
                return String(localized: "photo.access.description")
            }
        }
    }

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
    @Published private(set) var livePhotoAssets: [PHAsset] = []
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
    @Published private(set) var livePhotoCount = 0
    @Published private(set) var duplicateCandidateCount = 0
    @Published private(set) var burstCandidateCount = 0
    @Published private(set) var videoStorageBytes: Int64 = 0
    @Published private(set) var screenshotStorageBytes: Int64 = 0
    @Published private(set) var livePhotoStorageBytes: Int64 = 0
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
    nonisolated private static let mediaStorageRepairKey = "photoCleaner.mediaStorageRepair.v1"
    nonisolated private static let fallbackShotInterval: TimeInterval = 3
    nonisolated private static let fallbackSequenceDuration: TimeInterval = 10
    private let analysisCache = SimilarAnalysisCache()
    private let duplicateCache = DuplicateFingerprintCache()
    private let searchIndexStore = PhotoSearchIndexStore.shared
    private let monthlyReviewStore = MonthlyReviewStore()
    private let monthlyAlbumsCache = MonthlyAlbumsCache()
    private let detailGroupCache = DetailGroupCache()
    private var scanTask: Task<Void, Never>?
    private var searchIndexTask: Task<Void, Never>?
    private var libraryChangeDebounce: Task<Void, Never>?
    private var hasRequestedStartupScan = false
    private var hasScheduledDetailGroupWarmup = false
    private var isRestoringCachedDuplicates = false
    private var isRestoringCachedBursts = false
    private var didAttemptCachedDuplicateRestore = false
    private var didAttemptCachedBurstRestore = false
    private var isRestoringMediaAssets = false
    private var isRestoringEmptyAlbums = false
    private var isRestoringMonthlyReviewProgress = false
    private var shouldRepairCachedMediaStorage = false

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        restoreHomeSummary()
        hasCompletedInitialAnalysis = hasHomeSummary &&
            UserDefaults.standard.bool(forKey: Self.initialAnalysisCompleteKey)
        shouldRepairCachedMediaStorage = shouldRepairCachedMediaStorage ||
            (hasCompletedInitialAnalysis &&
                !UserDefaults.standard.bool(forKey: Self.mediaStorageRepairKey))
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
            guard !hasRequestedStartupScan else { return }
            hasRequestedStartupScan = true
            if hasCompletedInitialAnalysis {
                refreshSearchIndexInBackground()
                warmDetailGroupsIfNeeded()
                if shouldRepairCachedMediaStorage {
                    shouldRepairCachedMediaStorage = false
                    refreshLibrary()
                }
                return
            }
            refreshLibrary()
        }
    }

    func refreshAuthorizationStatus() {
        Task {
            let previousStatus = authorizationStatus
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            let hadAccess = previousStatus == .authorized || previousStatus == .limited
            let hasAccess = authorizationStatus == .authorized || authorizationStatus == .limited
            if !hadAccess, hasAccess, !hasHomeSummary {
                start()
            }
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
            livePhotoCount = 0
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
            restoreMonthlyReviewProgressIfNeeded()
            rebuildAllMonthlyProgress()
        }
    }

    private func applyHomeSummary(_ summary: HomeLibrarySummary) {
        photoCount = summary.photoCount
        videoCount = summary.videoCount
        screenshotCount = summary.screenshotCount
        livePhotoCount = summary.livePhotoCount ?? 0
        largeVideoCount = summary.largeVideoCount
        screenRecordingCount = summary.screenRecordingCount
        duplicateCandidateCount = summary.duplicateCandidateCount
        burstCandidateCount = summary.burstCandidateCount
        mediaStorageBytes = summary.mediaStorageBytes
        videoStorageBytes = summary.videoStorageBytes
        screenshotStorageBytes = summary.screenshotStorageBytes
        livePhotoStorageBytes = summary.livePhotoStorageBytes ?? 0
        largeVideoStorageBytes = summary.largeVideoStorageBytes
        screenRecordingStorageBytes = summary.screenRecordingStorageBytes
        duplicateCandidateStorageBytes = summary.duplicateCandidateStorageBytes
        burstCandidateStorageBytes = summary.burstCandidateStorageBytes
        emptyAlbumCount = summary.emptyAlbumCount
        hasHomeSummary = true
        isUsingCachedHomeSummary = true
        if Self.isSuspiciousMediaStorage(
            mediaStorageBytes: summary.mediaStorageBytes,
            videoStorageBytes: summary.videoStorageBytes,
            photoCount: summary.photoCount
        ) {
            shouldRepairCachedMediaStorage = true
        }
    }

    private func persistHomeSummary() {
        let summary = HomeLibrarySummary(
            photoCount: photoCount,
            videoCount: videoCount,
            screenshotCount: screenshotCount,
            livePhotoCount: livePhotoCount,
            largeVideoCount: largeVideoCount,
            screenRecordingCount: screenRecordingCount,
            duplicateCandidateCount: duplicateCandidateCount,
            burstCandidateCount: burstCandidateCount,
            mediaStorageBytes: mediaStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            livePhotoStorageBytes: livePhotoStorageBytes,
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
            didAttemptCachedDuplicateRestore = false
            didAttemptCachedBurstRestore = false
            if !hasHomeSummary {
                photoCount = 0
                videoCount = 0
                screenshotCount = 0
                livePhotoCount = 0
                largeVideoCount = 0
                screenRecordingCount = 0
                duplicateCandidateCount = 0
                burstCandidateCount = 0
                mediaStorageBytes = 0
                videoStorageBytes = 0
                screenshotStorageBytes = 0
                livePhotoStorageBytes = 0
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
            livePhotoAssets = snapshot.livePhotoAssets
            livePhotoCount = snapshot.livePhotoAssets.count
            videoAssets = snapshot.videoAssets
            largeVideoAssets = snapshot.largeVideoAssets
            largeVideoCount = snapshot.largeVideoAssets.count
            screenRecordingAssets = snapshot.screenRecordingAssets
            screenRecordingCount = snapshot.screenRecordingAssets.count
            monthGroups = snapshot.monthGroups
            persistMonthlyAlbums(from: snapshot.monthGroups)
            rebuildAllMonthlyProgress()
            if !hasCompletedInitialAnalysis {
                burstGroups = snapshot.initialBurstGroups
                burstCandidateCount = Self.cleanableCount(in: snapshot.initialBurstGroups)
                burstCandidateStorageBytes = snapshot.initialBurstCandidateStorageBytes
            }
            mediaStorageBytes = snapshot.mediaStorageBytes
            videoStorageBytes = snapshot.videoStorageBytes
            screenshotStorageBytes = snapshot.screenshotStorageBytes
            livePhotoStorageBytes = snapshot.livePhotoStorageBytes
            largeVideoStorageBytes = snapshot.largeVideoStorageBytes
            screenRecordingStorageBytes = snapshot.screenRecordingStorageBytes
            emptyAlbumCount = snapshot.emptyAlbumCount
            emptyAlbums = snapshot.emptyAlbums
            persistHomeSummary()
            UserDefaults.standard.set(true, forKey: Self.mediaStorageRepairKey)
            shouldRepairCachedMediaStorage = false
            await rebuildSearchIndexMetadata(
                for: snapshot.imageAssets + snapshot.videoAssets
            )
            startSearchOCRIndexing(for: snapshot.imageAssets)

            await restoreMonthlyReviewProgress()
            await Task.yield()

            let duplicateCacheComplete = await restoreDuplicateGroupsFromCache(
                in: snapshot.imageAssets
            )
            await persistDuplicateDetailGroups()
            persistHomeSummary()
            if !duplicateCacheComplete {
                await scanDuplicates(in: snapshot.imageAssets)
                await persistDuplicateDetailGroups()
                persistHomeSummary()
            }

            var analyzedBurstGroups = snapshot.initialBurstGroups
            let candidates = snapshot.burstCandidates
            let burstCacheComplete = await restoreBurstGroupsFromCache(
                candidates: candidates
            )
            if burstCacheComplete {
                analysisCacheSize = await analysisCache.sizeInBytes() +
                    duplicateCache.sizeInBytes() +
                    searchIndexStore.sizeInBytes() +
                    detailGroupCache.sizeInBytes()
                await persistBurstDetailGroups()
                persistHomeSummary()
                markInitialAnalysisComplete()
                scanState = .finished
                return
            }

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
                duplicateCache.sizeInBytes() +
                searchIndexStore.sizeInBytes() +
                detailGroupCache.sizeInBytes()
            await persistBurstDetailGroups()
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

    func preheatThumbnails(for assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        imageManager.startCachingImages(
            for: assets,
            targetSize: pixelSize,
            contentMode: .aspectFill,
            options: options
        )
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

    func restoreCachedDuplicateGroupsIfNeeded() {
        guard hasCompletedInitialAnalysis,
              duplicateGroups.isEmpty,
              duplicateCandidateCount > 0,
              !didAttemptCachedDuplicateRestore,
              !isRestoringCachedDuplicates else {
            return
        }
        isRestoringCachedDuplicates = true
        didAttemptCachedDuplicateRestore = true

        Task { [weak self] in
            guard let self else { return }
            let restoredFromDetailCache = await restoreDuplicateGroupsFromDetailCache(
                updateSummaryCounts: false
            )
            if !restoredFromDetailCache {
                let assets = await Task.detached(priority: .utility) {
                    Self.fetchImageAssets()
                }.value
                guard !Task.isCancelled else {
                    isRestoringCachedDuplicates = false
                    return
                }
                _ = await restoreDuplicateGroupsFromCache(
                    in: assets,
                    updateSummaryCounts: false
                )
                await persistDuplicateDetailGroups()
            }
            isRestoringCachedDuplicates = false
        }
    }

    func restoreCachedBurstGroupsIfNeeded() {
        guard hasCompletedInitialAnalysis,
              burstGroups.isEmpty,
              burstCandidateCount > 0,
              !didAttemptCachedBurstRestore,
              !isRestoringCachedBursts else {
            return
        }
        isRestoringCachedBursts = true
        didAttemptCachedBurstRestore = true

        Task { [weak self] in
            guard let self else { return }
            let restoredFromDetailCache = await restoreBurstGroupsFromDetailCache(
                updateSummaryCounts: false
            )
            if !restoredFromDetailCache {
                let candidates = await Task.detached(priority: .utility) {
                    let assets = Self.fetchImageAssets()
                    return Self.continuousShotCandidateGroups(
                        assets: assets,
                        maximumAdjacentInterval: Self.fallbackShotInterval,
                        maximumSequenceDuration: Self.fallbackSequenceDuration
                    )
                }.value
                guard !Task.isCancelled else {
                    isRestoringCachedBursts = false
                    return
                }
                _ = await restoreBurstGroupsFromCache(
                    candidates: candidates,
                    updateSummaryCounts: false
                )
                await persistBurstDetailGroups()
            }
            isRestoringCachedBursts = false
        }
    }

    func restoreMediaAssetsIfNeeded() {
        guard hasCompletedInitialAnalysis,
              !isRestoringMediaAssets,
              shouldRestoreMediaAssets else {
            return
        }
        isRestoringMediaAssets = true

        Task { [weak self] in
            guard let self else { return }

            // Phase 1: fast — populate asset arrays immediately
            let fastSnapshot = await Task.detached(priority: .userInitiated) {
                Self.makeFastMediaAssetSnapshot()
            }.value
            guard !Task.isCancelled else {
                isRestoringMediaAssets = false
                return
            }

            screenshotAssets = fastSnapshot.screenshotAssets
            screenshotCount = fastSnapshot.screenshotAssets.count
            livePhotoAssets = fastSnapshot.livePhotoAssets
            livePhotoCount = fastSnapshot.livePhotoAssets.count
            videoAssets = fastSnapshot.videoAssets
            videoCount = fastSnapshot.videoAssets.count
            largeVideoAssets = fastSnapshot.largeVideoAssets
            largeVideoCount = fastSnapshot.largeVideoAssets.count
            screenRecordingAssets = fastSnapshot.screenRecordingAssets
            screenRecordingCount = fastSnapshot.screenRecordingAssets.count

            // Phase 2: slow — compute storage bytes in background
            let storageValues = await Task.detached(priority: .utility) {
                Self.computeStorageForAssets(
                    screenshots: fastSnapshot.screenshotAssets,
                    livePhotos: fastSnapshot.livePhotoAssets,
                    videos: fastSnapshot.videoAssets,
                    largeVideos: fastSnapshot.largeVideoAssets,
                    recordings: fastSnapshot.screenRecordingAssets
                )
            }.value
            guard !Task.isCancelled else {
                isRestoringMediaAssets = false
                return
            }

            videoStorageBytes = storageValues.videoStorageBytes
            screenshotStorageBytes = storageValues.screenshotStorageBytes
            livePhotoStorageBytes = storageValues.livePhotoStorageBytes
            largeVideoStorageBytes = storageValues.largeVideoStorageBytes
            screenRecordingStorageBytes = storageValues.screenRecordingStorageBytes
            persistHomeSummary()
            isRestoringMediaAssets = false
        }
    }

    private var shouldRestoreMediaAssets: Bool {
        (screenshotAssets.isEmpty && screenshotCount > 0) ||
            (livePhotoAssets.isEmpty && livePhotoCount > 0) ||
            (videoAssets.isEmpty && videoCount > 0) ||
            (largeVideoAssets.isEmpty && largeVideoCount > 0) ||
            (screenRecordingAssets.isEmpty && screenRecordingCount > 0)
    }

    func restoreEmptyAlbumsIfNeeded() {
        guard hasCompletedInitialAnalysis,
              emptyAlbums.isEmpty,
              emptyAlbumCount > 0,
              !isRestoringEmptyAlbums else {
            return
        }
        isRestoringEmptyAlbums = true

        Task { [weak self] in
            guard let self else { return }
            let albums = await Task.detached(priority: .userInitiated) {
                Self.fetchEmptyAlbums()
            }.value
            guard !Task.isCancelled else {
                isRestoringEmptyAlbums = false
                return
            }

            emptyAlbums = albums
            emptyAlbumCount = albums.count
            persistHomeSummary()
            isRestoringEmptyAlbums = false
        }
    }

    nonisolated func storageBytes(for asset: PHAsset) -> Int64 {
        Self.assetStorageBytes(asset)
    }

    nonisolated func liveMotionBytes(for asset: PHAsset) -> Int64 {
        Self.liveMotionStorageBytes(asset)
    }

    nonisolated func recommendedLivePhotoSlimmingIDs(
        for assets: [PHAsset]
    ) async -> Set<String> {
        var identifiers = Set<String>()
        identifiers.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { return identifiers }
            if await Self.shouldRecommendLivePhotoSlimmingWithVision(for: asset) {
                identifiers.insert(asset.localIdentifier)
            }
            if index.isMultiple(of: 4) {
                await Task.yield()
            }
        }

        return identifiers
    }

    func convertLivePhotosToStill(with identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(identifiers),
            options: nil
        )
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoLive) {
                assets.append(asset)
            }
        }
        guard !assets.isEmpty else { return }

        var stillImageURLsByID: [String: URL] = [:]
        stillImageURLsByID.reserveCapacity(assets.count)
        let albumIDsByAssetID = Self.userAlbumIDsByAssetID(for: assets)
        do {
            for asset in assets {
                stillImageURLsByID[asset.localIdentifier] = try await stillImageFileURL(for: asset)
            }
            try await PHPhotoLibrary.shared().performChanges {
                var createdPlaceholdersByAlbumID: [String: [PHObjectPlaceholder]] = [:]
                for asset in assets {
                    guard let url = stillImageURLsByID[asset.localIdentifier] else { continue }
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    request.addResource(with: .photo, fileURL: url, options: options)
                    request.creationDate = asset.creationDate
                    request.location = asset.location
                    request.isFavorite = asset.isFavorite
                    if let placeholder = request.placeholderForCreatedAsset {
                        for albumID in albumIDsByAssetID[asset.localIdentifier, default: []] {
                            createdPlaceholdersByAlbumID[albumID, default: []].append(placeholder)
                        }
                    }
                }
                for (albumID, placeholders) in createdPlaceholdersByAlbumID {
                    let collections = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [albumID],
                        options: nil
                    )
                    guard let collection = collections.firstObject,
                          let request = PHAssetCollectionChangeRequest(for: collection) else {
                        continue
                    }
                    request.addAssets(placeholders as NSArray)
                }
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }
        } catch {
            for url in stillImageURLsByID.values {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        for url in stillImageURLsByID.values {
            try? FileManager.default.removeItem(at: url)
        }

        let convertedIDs = Set(assets.map(\.localIdentifier))
        livePhotoAssets.removeAll { convertedIDs.contains($0.localIdentifier) }
        livePhotoCount = livePhotoAssets.count
        livePhotoStorageBytes = livePhotoAssets.reduce(Int64(0)) {
            $0 + Self.assetStorageBytes($1)
        }
        persistHomeSummary()
    }

    private func stillImageFileURL(for asset: PHAsset) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in true }
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let sourceURL = input?.fullSizeImageURL else {
                    continuation.resume(throwing: NSError(
                        domain: "PhotoCleaner.LivePhoto",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to read still image"]
                    ))
                    return
                }
                let targetURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension)
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                    continuation.resume(returning: targetURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func userAlbumIDsByAssetID(for assets: [PHAsset]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for asset in assets {
            let collections = PHAssetCollection.fetchAssetCollectionsContaining(
                asset,
                with: .album,
                options: nil
            )
            collections.enumerateObjects { collection, _, _ in
                result[asset.localIdentifier, default: []].append(collection.localIdentifier)
            }
        }
        return result
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
        emptyAlbums.removeAll { $0.id == localIdentifier }
        emptyAlbumCount = emptyAlbums.count
        persistHomeSummary()
    }

    func deleteAssets(with identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(result)
        }
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
        searchIndexTask?.cancel()
        hasScheduledDetailGroupWarmup = false
        didAttemptCachedDuplicateRestore = false
        didAttemptCachedBurstRestore = false
        hasCompletedInitialAnalysis = false
        UserDefaults.standard.removeObject(forKey: Self.initialAnalysisCompleteKey)
        UserDefaults.standard.removeObject(forKey: Self.mediaStorageRepairKey)
        Task {
            try? await analysisCache.clear()
            try? await duplicateCache.clear()
            try? await searchIndexStore.clear()
            try? await monthlyAlbumsCache.clear()
            try? await detailGroupCache.clear()
            analysisCacheSize = 0
            scanState = .idle
        }
    }

    func exportSmartSearchDebugIndex() async throws -> URL {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw SmartSearchDebugExportError.photoAccessRequired
        }

        searchIndexTask?.cancel()

        let imageAssets = Self.fetchImageAssets()
        try await searchIndexStore.rebuildMetadata(for: imageAssets)
        await Self.indexSearchImagesIfNeeded(for: imageAssets)
        let fileURL = try await searchIndexStore.exportDebugSnapshot(for: imageAssets)
        analysisCacheSize = await analysisCache.sizeInBytes() +
            duplicateCache.sizeInBytes() +
            searchIndexStore.sizeInBytes() +
            detailGroupCache.sizeInBytes()
        return fileURL
    }

    private func refreshSearchIndexInBackground() {
        searchIndexTask?.cancel()
        searchIndexTask = Task.detached(priority: .background) {
            let imageAssets = Self.fetchImageAssets()
            let videoAssets = Self.fetchVideoAssets()
            try? await PhotoSearchIndexStore.shared.rebuildMetadata(
                for: imageAssets + videoAssets
            )
            await Self.indexSearchImagesIfNeeded(for: imageAssets)
        }
    }

    private func warmDetailGroupsIfNeeded() {
        guard hasCompletedInitialAnalysis,
              !hasScheduledDetailGroupWarmup else {
            return
        }
        hasScheduledDetailGroupWarmup = true
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let hasCachedGroups = await detailGroupCache.hasAnyCachedGroups()
            guard !hasCachedGroups else { return }

            let assets = Self.fetchImageAssets()
            _ = await restoreDuplicateGroupsFromCache(
                in: assets,
                updateSummaryCounts: false
            )
            await persistDuplicateDetailGroups()

            let candidates = Self.continuousShotCandidateGroups(
                assets: assets,
                maximumAdjacentInterval: Self.fallbackShotInterval,
                maximumSequenceDuration: Self.fallbackSequenceDuration
            )
            _ = await restoreBurstGroupsFromCache(
                candidates: candidates,
                updateSummaryCounts: false
            )
            await persistBurstDetailGroups()
        }
    }

    private func rebuildSearchIndexMetadata(for assets: [PHAsset]) async {
        try? await searchIndexStore.rebuildMetadata(for: assets)
        analysisCacheSize = await analysisCache.sizeInBytes() +
            duplicateCache.sizeInBytes() +
            searchIndexStore.sizeInBytes() +
            detailGroupCache.sizeInBytes()
    }

    private func startSearchOCRIndexing(for assets: [PHAsset]) {
        searchIndexTask?.cancel()
        searchIndexTask = Task.detached(priority: .background) {
            await Self.indexSearchImagesIfNeeded(for: assets)
        }
    }

    nonisolated private static func indexSearchImagesIfNeeded(for assets: [PHAsset]) async {
        let ocrPending = await PhotoSearchIndexStore.shared.assetsNeedingOCR(from: assets)
        let visualPending = await PhotoSearchIndexStore.shared.imageAssetsNeedingVisualIndex(from: assets)
        let pendingIDs = Set((ocrPending + visualPending).map(\.localIdentifier))
        let pending = assets.filter { pendingIDs.contains($0.localIdentifier) }
        var batch: [(asset: PHAsset, ocrText: String, visualTags: [String])] = []
        batch.reserveCapacity(12)
        for (index, asset) in pending.enumerated() {
            guard !Task.isCancelled else { return }
            let analysis = await searchImageAnalysis(for: asset)
            batch.append((asset, analysis.ocrText, analysis.visualTags))
            if batch.count >= 12 {
                try? await PhotoSearchIndexStore.shared.updateSearchAnalyses(batch)
                batch.removeAll(keepingCapacity: true)
            }
            if index.isMultiple(of: 5) {
                await Task.yield()
            }
        }
        try? await PhotoSearchIndexStore.shared.updateSearchAnalyses(batch)
    }

    nonisolated private static func searchImageAnalysis(
        for asset: PHAsset
    ) async -> (ocrText: String, visualTags: [String]) {
        guard let image = await requestSearchAnalysisImage(for: asset),
              let cgImage = image.cgImage else {
            return ("", [])
        }
        return (
            searchRecognizedText(for: cgImage) ?? "",
            searchVisualTags(for: cgImage)
        )
    }

    nonisolated private static func searchRecognizedText(for asset: PHAsset) async -> String? {
        guard let image = await requestSearchAnalysisImage(for: asset),
              let cgImage = image.cgImage else {
            return nil
        }
        return searchRecognizedText(for: cgImage)
    }

    nonisolated private static func searchRecognizedText(for cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
            return request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            return nil
        }
    }

    nonisolated private static func requestSearchAnalysisImage(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 900, height: 900),
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

    nonisolated private static func shouldRecommendLivePhotoSlimmingWithVision(
        for asset: PHAsset
    ) async -> Bool {
        guard asset.mediaSubtypes.contains(.photoLive),
              !asset.isFavorite else {
            return false
        }

        let motionBytes = liveMotionStorageBytes(asset)
        let totalBytes = assetStorageBytes(asset)
        let hasUsefulSaving = motionBytes >= 1_000_000 ||
            Double(motionBytes) >= Double(totalBytes) * 0.35
        guard hasUsefulSaving,
              let image = await requestLiveRecommendationImage(for: asset),
              let cgImage = image.cgImage else {
            return false
        }

        return detectedHumanRects(in: cgImage).isEmpty
    }

    nonisolated private static func requestLiveRecommendationImage(
        for asset: PHAsset
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 480, height: 480),
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

    nonisolated private static func searchVisualTags(for image: CGImage) -> [String] {
        var tags = Set<String>()
        tags.formUnion(classificationTags(for: image))

        let humanRects = detectedHumanRects(in: image)
        if !humanRects.isEmpty {
            tags.insert("person")
            tags.insert("people")
            tags.insert("human")
        }

        if let color = dominantColorTag(in: image, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)) {
            tags.insert(color)
        }

        for rect in humanRects.prefix(3) {
            let clothingRect = CGRect(
                x: rect.minX + rect.width * 0.18,
                y: rect.minY + rect.height * 0.20,
                width: rect.width * 0.64,
                height: rect.height * 0.45
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clothingRect.isNull,
                  let color = dominantColorTag(in: image, normalizedRect: clothingRect) else {
                continue
            }
            tags.insert("\(color)_clothing")
            tags.insert("clothing")
        }

        return tags.sorted()
    }

    nonisolated private static func classificationTags(for image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
            return request.results?
                .filter { $0.confidence >= 0.25 }
                .prefix(8)
                .flatMap { observation in
                    observation.identifier
                        .split(separator: ",")
                        .map { normalizedClassificationTag(String($0)) }
                        .filter { !$0.isEmpty }
                } ?? []
        } catch {
            return []
        }
    }

    nonisolated private static func normalizedClassificationTag(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .joined(separator: "_")
            .lowercased()
    }

    nonisolated private static func detectedHumanRects(in image: CGImage) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
            return request.results?
                .map(\.boundingBox)
                .filter { $0.width * $0.height > 0.03 } ?? []
        } catch {
            return []
        }
    }

    nonisolated private static func dominantColorTag(
        in image: CGImage,
        normalizedRect: CGRect
    ) -> String? {
        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleRect = normalizedRect
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !sampleRect.isNull else { return nil }

        let minX = max(Int((sampleRect.minX * CGFloat(width)).rounded(.down)), 0)
        let maxX = min(Int((sampleRect.maxX * CGFloat(width)).rounded(.up)), width)
        let minY = max(Int(((1 - sampleRect.maxY) * CGFloat(height)).rounded(.down)), 0)
        let maxY = min(Int(((1 - sampleRect.minY) * CGFloat(height)).rounded(.up)), height)

        var buckets: [String: Int] = [:]
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                guard let tag = colorTag(red: red, green: green, blue: blue) else {
                    continue
                }
                buckets[tag, default: 0] += 1
            }
        }
        return buckets.max { $0.value < $1.value }?.key
    }

    nonisolated private static func colorTag(red: Double, green: Double, blue: Double) -> String? {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        let brightness = maxValue
        guard brightness > 0.18 else { return "black" }
        if delta < 0.10 {
            return brightness > 0.78 ? "white" : "gray"
        }

        let hue: Double
        if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maxValue == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }
        let normalizedHue = hue < 0 ? hue + 1 : hue
        switch normalizedHue {
        case 0..<0.045, 0.94...1:
            return "red"
        case 0.045..<0.11:
            return "orange"
        case 0.11..<0.18:
            return "yellow"
        case 0.18..<0.43:
            return "green"
        case 0.43..<0.72:
            return "blue"
        case 0.72..<0.86:
            return "purple"
        default:
            return "red"
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
        rebuildAllMonthlyProgress()
        try? await monthlyReviewStore.save(monthlyReviewStates())
    }

    func restoreMonthlyReviewProgressIfNeeded() {
        guard !monthGroups.isEmpty,
              !isRestoringMonthlyReviewProgress else {
            return
        }
        isRestoringMonthlyReviewProgress = true

        Task { [weak self] in
            guard let self else { return }
            await restoreMonthlyReviewProgress()
            isRestoringMonthlyReviewProgress = false
        }
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

    private func restoreDuplicateGroupsFromCache(
        in assets: [PHAsset],
        updateSummaryCounts: Bool = true
    ) async -> Bool {
        let cached = await duplicateCache.validFingerprints(for: assets)
        guard !cached.isEmpty else {
            if updateSummaryCounts {
                hasDuplicateScanResults = false
            }
            return assets.isEmpty
        }

        let groups = Self.makeDuplicateGroups(
            from: assets,
            fingerprints: cached.mapValues(\.fingerprint)
        )
        applyDuplicateGroups(groups, updateSummaryCounts: updateSummaryCounts)
        return cached.count == assets.count
    }

    private func restoreDuplicateGroupsFromDetailCache(
        updateSummaryCounts: Bool = true
    ) async -> Bool {
        let cachedGroups = await detailGroupCache.loadDuplicateGroups()
        guard !cachedGroups.isEmpty else { return false }
        let groups = Self.restoreDetailGroups(from: cachedGroups)
        guard !groups.isEmpty else { return false }
        applyDuplicateGroups(groups, updateSummaryCounts: updateSummaryCounts)
        return groups.count == cachedGroups.count
    }

    private func restoreBurstGroupsFromCache(
        candidates: [[PHAsset]],
        updateSummaryCounts: Bool = true
    ) async -> Bool {
        guard !candidates.isEmpty else {
            burstGroups = []
            if updateSummaryCounts {
                burstCandidateCount = 0
                burstCandidateStorageBytes = 0
            }
            return true
        }

        var restoredGroups: [SimilarAssetGroup] = []
        var hasMissingCache = false

        for candidate in candidates {
            let signature = SimilarAnalysisSignature.make(for: candidate)
            guard let cached = await analysisCache.group(for: signature) else {
                hasMissingCache = true
                continue
            }
            if let group = Self.restoreGroup(cached, from: candidate) {
                restoredGroups.append(group)
            }
        }

        burstGroups = restoredGroups.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        if updateSummaryCounts {
            burstCandidateCount = Self.cleanableCount(in: burstGroups)
            burstCandidateStorageBytes = Self.cleanableStorageBytes(in: burstGroups)
        }
        return !hasMissingCache
    }

    private func restoreBurstGroupsFromDetailCache(
        updateSummaryCounts: Bool = true
    ) async -> Bool {
        let cachedGroups = await detailGroupCache.loadBurstGroups()
        guard !cachedGroups.isEmpty else { return false }
        let groups = Self.restoreDetailGroups(from: cachedGroups)
        guard !groups.isEmpty else { return false }
        burstGroups = groups.sorted {
            ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
        }
        if updateSummaryCounts {
            burstCandidateCount = Self.cleanableCount(in: burstGroups)
            burstCandidateStorageBytes = Self.cleanableStorageBytes(in: burstGroups)
        }
        return groups.count == cachedGroups.count
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

    private func persistDuplicateDetailGroups() async {
        try? await detailGroupCache.saveDuplicateGroups(duplicateGroups)
    }

    private func persistBurstDetailGroups() async {
        try? await detailGroupCache.saveBurstGroups(burstGroups)
    }

    private func applyDuplicateGroups(
        _ groups: [SimilarAssetGroup],
        updateSummaryCounts: Bool = true
    ) {
        duplicateGroups = groups
        if updateSummaryCounts {
            duplicateCandidateCount = Self.cleanableCount(in: groups)
            duplicateCandidateStorageBytes = Self.cleanableStorageBytes(in: groups)
        }
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
        let livePhotoAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoLive) }
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
        let livePhotoStorageBytes = storageBytes(
            for: livePhotoAssets,
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
            livePhotoAssets: livePhotoAssets,
            largeVideoAssets: largeVideoAssets,
            screenRecordingAssets: screenRecordingAssets,
            monthGroups: monthGroups,
            burstCandidates: burstCandidates,
            initialBurstGroups: initialBurstGroups,
            mediaStorageBytes: imageStorageBytes + videoStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            livePhotoStorageBytes: livePhotoStorageBytes,
            largeVideoStorageBytes: largeVideoStorageBytes,
            screenRecordingStorageBytes: screenRecordingStorageBytes,
            initialBurstCandidateStorageBytes: burstCandidateStorageBytes,
            emptyAlbumCount: emptyAlbums.count,
            emptyAlbums: emptyAlbums
        )
    }

    nonisolated private static func makeFastMediaAssetSnapshot() -> MediaAssetSnapshot {
        let imageAssets = fetchImageAssets()
        let videos = fetchVideoAssets()
        let screenshotAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoScreenshot) }
                .reversed()
        )
        let livePhotoAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoLive) }
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
        return MediaAssetSnapshot(
            screenshotAssets: screenshotAssets,
            livePhotoAssets: livePhotoAssets,
            videoAssets: videoAssets,
            largeVideoAssets: largeVideoAssets,
            screenRecordingAssets: screenRecordingAssets,
            mediaStorageBytes: 0,
            videoStorageBytes: 0,
            screenshotStorageBytes: 0,
            livePhotoStorageBytes: 0,
            largeVideoStorageBytes: 0,
            screenRecordingStorageBytes: 0
        )
    }

    private struct StorageValues {
        let videoStorageBytes: Int64
        let screenshotStorageBytes: Int64
        let livePhotoStorageBytes: Int64
        let largeVideoStorageBytes: Int64
        let screenRecordingStorageBytes: Int64
        let totalStorageBytes: Int64
    }

    nonisolated private static func computeStorageForAssets(
        screenshots: [PHAsset],
        livePhotos: [PHAsset],
        videos: [PHAsset],
        largeVideos: [PHAsset],
        recordings: [PHAsset]
    ) -> StorageValues {
        let imageStorageByID = storageMap(for: screenshots)
            .merging(storageMap(for: livePhotos)) { current, _ in current }
        let videoStorageByID = storageMap(for: videos)
        let imageStorageBytes = imageStorageByID.values.reduce(Int64(0), +)
        let videoStorageBytes = videoStorageByID.values.reduce(Int64(0), +)
        return StorageValues(
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: storageBytes(for: screenshots, storageByID: imageStorageByID),
            livePhotoStorageBytes: storageBytes(for: livePhotos, storageByID: imageStorageByID),
            largeVideoStorageBytes: storageBytes(for: largeVideos, storageByID: videoStorageByID),
            screenRecordingStorageBytes: storageBytes(for: recordings, storageByID: videoStorageByID),
            totalStorageBytes: imageStorageBytes + videoStorageBytes
        )
    }

    nonisolated private static func makeMediaAssetSnapshot() -> MediaAssetSnapshot {
        let imageAssets = fetchImageAssets()
        let videos = fetchVideoAssets()
        let imageStorageByID = storageMap(for: imageAssets)
        let videoStorageByID = storageMap(for: videos)
        let screenshotAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoScreenshot) }
                .reversed()
        )
        let livePhotoAssets = Array(
            imageAssets
                .filter { $0.mediaSubtypes.contains(.photoLive) }
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
        let imageStorageBytes = imageStorageByID.values.reduce(Int64(0), +)
        let videoStorageBytes = videoStorageByID.values.reduce(Int64(0), +)

        return MediaAssetSnapshot(
            screenshotAssets: screenshotAssets,
            livePhotoAssets: livePhotoAssets,
            videoAssets: videoAssets,
            largeVideoAssets: largeVideoAssets,
            screenRecordingAssets: screenRecordingAssets,
            mediaStorageBytes: imageStorageBytes + videoStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: storageBytes(
                for: screenshotAssets,
                storageByID: imageStorageByID
            ),
            livePhotoStorageBytes: storageBytes(
                for: livePhotoAssets,
                storageByID: imageStorageByID
            ),
            largeVideoStorageBytes: storageBytes(
                for: largeVideoAssets,
                storageByID: videoStorageByID
            ),
            screenRecordingStorageBytes: storageBytes(
                for: screenRecordingAssets,
                storageByID: videoStorageByID
            )
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

    nonisolated private static func isSuspiciousMediaStorage(
        mediaStorageBytes: Int64,
        videoStorageBytes: Int64,
        photoCount: Int
    ) -> Bool {
        photoCount > 0 && videoStorageBytes > 0 && mediaStorageBytes <= videoStorageBytes
    }

    nonisolated private static func liveMotionStorageBytes(_ asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { total, resource in
            guard resource.type == .pairedVideo,
                  let fileSize = resource.value(forKey: "fileSize") as? NSNumber else {
                return total
            }
            return total + fileSize.int64Value
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

    nonisolated private static func restoreDetailGroups(
        from cachedGroups: [CachedDetailGroup]
    ) -> [SimilarAssetGroup] {
        let localIdentifiers = Array(
            Set(cachedGroups.flatMap { $0.assets.map(\.id) })
        )
        guard !localIdentifiers.isEmpty else { return [] }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: localIdentifiers,
            options: nil
        )
        var assetsByID: [String: PHAsset] = [:]
        assetsByID.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assetsByID[asset.localIdentifier] = asset
        }

        return cachedGroups.compactMap { cachedGroup in
            let restoredAssets = cachedGroup.assets.compactMap { item -> SimilarAsset? in
                guard let asset = assetsByID[item.id],
                      CachedDetailGroupAssetSignature.make(for: asset) == item.signature else {
                    return nil
                }
                return SimilarAsset(
                    id: item.id,
                    asset: asset,
                    qualityScore: item.qualityScore,
                    isBest: item.isBest
                )
            }
            guard restoredAssets.count >= 2 else { return nil }
            return SimilarAssetGroup(
                id: restoredAssets.map(\.id).sorted().joined(separator: "|"),
                assets: restoredAssets,
                creationDate: restoredAssets.compactMap(\.asset.creationDate).min()
            )
        }
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
                Image(systemName: "photo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.55))
            }

            if asset.mediaSubtypes.contains(.photoLive) {
                Label("LIVE", systemImage: "livephoto")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
                    .allowsHitTesting(false)
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
