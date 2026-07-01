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

struct IdentifiablePHAsset: Identifiable, Hashable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: IdentifiablePHAsset, rhs: IdentifiablePHAsset) -> Bool {
        lhs.id == rhs.id
    }
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
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let livePhotoStorageBytes: Int64
    let largeVideoStorageBytes: Int64
    let screenRecordingStorageBytes: Int64
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
    let mediaStorageBytes: Int64
    let videoStorageBytes: Int64
    let screenshotStorageBytes: Int64
    let livePhotoStorageBytes: Int64?
    let largeVideoStorageBytes: Int64
    let screenRecordingStorageBytes: Int64
    let duplicateCandidateStorageBytes: Int64
    let emptyAlbumCount: Int
}

private struct LegacyHomeLibrarySummary: Codable {
    let photoCount: Int
    let videoCount: Int
    let screenshotCount: Int
    let largeVideoCount: Int
    let screenRecordingCount: Int
    let duplicateCandidateCount: Int
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
                return AppLanguageSettings.shared.string("photo.access.description")
            }
        }
    }

    enum ScanState: Equatable {
        case idle
        case loadingLibrary
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
    @Published private(set) var videoStorageBytes: Int64 = 0
    @Published private(set) var screenshotStorageBytes: Int64 = 0
    @Published private(set) var livePhotoStorageBytes: Int64 = 0
    @Published private(set) var largeVideoStorageBytes: Int64 = 0
    @Published private(set) var screenRecordingStorageBytes: Int64 = 0
    @Published private(set) var duplicateCandidateStorageBytes: Int64 = 0
    @Published private(set) var emptyAlbumCount = 0
    @Published private(set) var emptyAlbums: [(id: String, title: String)] = []
    @Published private(set) var monthlyProgress: [String: Double] = [:]
    @Published private(set) var monthlyReviewedCounts: [String: Int] = [:]

    let imageManager = PHCachingImageManager()

    nonisolated private static let homeSummaryKey = "photoCleaner.homeLibrarySummary.v1"
    nonisolated private static let initialAnalysisCompleteKey = "photoCleaner.initialAnalysisComplete.v1"
    nonisolated private static let mediaStorageRepairKey = "photoCleaner.mediaStorageRepair.v1"
    private let duplicateCache = DuplicateFingerprintCache()
    private let searchIndexStore = PhotoSearchIndexStore.shared
    private let monthlyReviewStore = MonthlyReviewStore()
    private let monthlyAlbumsCache = MonthlyAlbumsCache()
    private let detailGroupCache = DetailGroupCache()
    private var scanTask: Task<Void, Never>?
    private var libraryChangeDebounce: Task<Void, Never>?
    private var hasRequestedStartupScan = false
    private var hasScheduledDetailGroupWarmup = false
    private var isRestoringCachedDuplicates = false
    private var didAttemptCachedDuplicateRestore = false
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
        mediaStorageBytes = summary.mediaStorageBytes
        videoStorageBytes = summary.videoStorageBytes
        screenshotStorageBytes = summary.screenshotStorageBytes
        livePhotoStorageBytes = summary.livePhotoStorageBytes ?? 0
        largeVideoStorageBytes = summary.largeVideoStorageBytes
        screenRecordingStorageBytes = summary.screenRecordingStorageBytes
        duplicateCandidateStorageBytes = summary.duplicateCandidateStorageBytes
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
            mediaStorageBytes: mediaStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            livePhotoStorageBytes: livePhotoStorageBytes,
            largeVideoStorageBytes: largeVideoStorageBytes,
            screenRecordingStorageBytes: screenRecordingStorageBytes,
            duplicateCandidateStorageBytes: duplicateCandidateStorageBytes,
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
            if !hasHomeSummary {
                photoCount = 0
                videoCount = 0
                screenshotCount = 0
                livePhotoCount = 0
                largeVideoCount = 0
                screenRecordingCount = 0
                duplicateCandidateCount = 0
                mediaStorageBytes = 0
                videoStorageBytes = 0
                screenshotStorageBytes = 0
                livePhotoStorageBytes = 0
                largeVideoStorageBytes = 0
                screenRecordingStorageBytes = 0
                duplicateCandidateStorageBytes = 0
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

            analysisCacheSize = await duplicateCache.sizeInBytes() +
                searchIndexStore.sizeInBytes() +
                detailGroupCache.sizeInBytes()
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
        options.deliveryMode = .fastFormat
        options.version = .current
        options.isNetworkAccessAllowed = true

        return imageManager.requestPlayerItem(
            forVideo: asset,
            options: options
        ) { playerItem, _ in
            Task { @MainActor in
                completion(playerItem)
            }
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

    func resetMonthlyReview(for monthID: String) {
        monthlyReviewedIDs.removeValue(forKey: monthID)
        monthlyMarkedIDs.removeValue(forKey: monthID)
        rebuildMonthlyProgress(for: monthID)
        persistMonthlyReviewProgress()
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
        hasScheduledDetailGroupWarmup = false
        didAttemptCachedDuplicateRestore = false
        hasCompletedInitialAnalysis = false
        UserDefaults.standard.removeObject(forKey: Self.initialAnalysisCompleteKey)
        UserDefaults.standard.removeObject(forKey: Self.mediaStorageRepairKey)
        Task {
            await SearchIndexRunCoordinator.shared.cancel()
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

        await SearchIndexRunCoordinator.shared.cancel()

        let imageAssets = Self.fetchImageAssets()
        try await searchIndexStore.rebuildMetadata(for: imageAssets)
        await Self.indexSearchImagesIfNeeded(for: imageAssets)
        let fileURL = try await searchIndexStore.exportDebugSnapshot(for: imageAssets)
        analysisCacheSize = await duplicateCache.sizeInBytes() +
            searchIndexStore.sizeInBytes() +
            detailGroupCache.sizeInBytes()
        return fileURL
    }

    private func refreshSearchIndexInBackground() {
        Task {
            await SearchIndexRunCoordinator.shared.start(force: false) {
#if DEBUG
                SearchOCRDebugLog.info("background index task started")
#endif
                let imageAssets = Self.fetchImageAssets()
                let videoAssets = Self.fetchVideoAssets()
                try? await PhotoSearchIndexStore.shared.rebuildMetadata(
                    for: imageAssets + videoAssets
                )
                await Self.indexSearchImagesIfNeeded(for: imageAssets)
            }
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
        }
    }

    private func rebuildSearchIndexMetadata(for assets: [PHAsset]) async {
        try? await searchIndexStore.rebuildMetadata(for: assets)
        analysisCacheSize = await duplicateCache.sizeInBytes() +
            searchIndexStore.sizeInBytes() +
            detailGroupCache.sizeInBytes()
    }

    private func startSearchOCRIndexing(for assets: [PHAsset]) {
        Task {
            await SearchIndexRunCoordinator.shared.start(force: true) {
                await Self.indexSearchImagesIfNeeded(for: assets)
            }
        }
    }

    nonisolated private static func indexSearchImagesIfNeeded(for assets: [PHAsset]) async {
#if DEBUG
        let summary = await PhotoSearchIndexStore.shared.ocrIndexDebugSummary(for: assets)
        SearchOCRDebugLog.info(
            "stats \(summary) langs=\(SearchOCRSettings.recognitionLanguages().joined(separator: ","))"
        )
#endif
        let ocrPending = await PhotoSearchIndexStore.shared.assetsNeedingOCR(from: assets)
        let visualPending = await PhotoSearchIndexStore.shared.imageAssetsNeedingVisualIndex(from: assets)
        let pendingIDs = Set((ocrPending + visualPending).map(\.localIdentifier))
        let pending = assets
            .filter { pendingIDs.contains($0.localIdentifier) }
            .sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
#if DEBUG
        SearchOCRDebugLog.info(
            "start pending=\(pending.count) probe=\(SearchOCRSettings.maxImageProbeEdge) ocrEdge=\(SearchOCRSettings.maxImageEdge) workers=\(SearchOCRSettings.indexConcurrency)"
        )
#endif
        guard !pending.isEmpty else {
            let enrichOnly = await PhotoSearchIndexStore.shared.assetsNeedingTagEnrichment(from: assets)
            guard !enrichOnly.isEmpty else { return }
#if DEBUG
            SearchOCRDebugLog.logEnrichPhaseStart(pending: enrichOnly.count)
#endif
            await indexTagEnrichmentPass(for: enrichOnly)
            return
        }

        let visualStarted = CFAbsoluteTimeGetCurrent()
        let ocrQueue = await indexVisualTagsPass(for: pending)
#if DEBUG
        let visualSeconds = CFAbsoluteTimeGetCurrent() - visualStarted
        SearchOCRDebugLog.info(
            "phase1 visual done \(pending.count - ocrQueue.count)/\(pending.count) skip, ocrQueue=\(ocrQueue.count) (\(String(format: "%.1f", visualSeconds))s)"
        )
#endif
        guard !ocrQueue.isEmpty else {
            let enrichOnly = await PhotoSearchIndexStore.shared.assetsNeedingTagEnrichment(from: assets)
            guard !enrichOnly.isEmpty else { return }
            await indexTagEnrichmentPass(for: enrichOnly)
            return
        }

        let ocrStarted = CFAbsoluteTimeGetCurrent()
        await indexOCRPass(for: ocrQueue)
#if DEBUG
        let ocrSeconds = CFAbsoluteTimeGetCurrent() - ocrStarted
        SearchOCRDebugLog.info(
            "phase2 ocr done \(ocrQueue.count)/\(ocrQueue.count) (\(String(format: "%.1f", ocrSeconds))s)"
        )
#endif

        let enrichPending = await PhotoSearchIndexStore.shared.assetsNeedingTagEnrichment(from: assets)
        guard !enrichPending.isEmpty else { return }

#if DEBUG
        SearchOCRDebugLog.logEnrichPhaseStart(pending: enrichPending.count)
#endif
        let enrichStarted = CFAbsoluteTimeGetCurrent()
        await indexTagEnrichmentPass(for: enrichPending)
#if DEBUG
        let enrichSeconds = CFAbsoluteTimeGetCurrent() - enrichStarted
        SearchOCRDebugLog.logEnrichPhaseDone(total: enrichPending.count, seconds: enrichSeconds)
#endif
    }

    /// 阶段 1：384px 分类 + 视觉 tag；~84% 直接跳过 OCR
    nonisolated private static func indexVisualTagsPass(for pending: [PHAsset]) async -> [PHAsset] {
        var skipBatch: [(asset: PHAsset, ocrText: String, visualTags: [String])] = []
        skipBatch.reserveCapacity(12)
        var ocrQueue: [PHAsset] = []
        ocrQueue.reserveCapacity(pending.count / 5)
        var visualOnlyBatch: [(asset: PHAsset, visualTags: [String])] = []
        visualOnlyBatch.reserveCapacity(12)
        let batchLock = NSLock()
        var completed = 0

        await withTaskGroup(of: (asset: PHAsset, needsOCR: Bool, visualTags: [String], index: Int).self) { group in
            var nextIndex = 0
            let workerCount = max(1, SearchOCRSettings.indexConcurrency)

            func enqueue(_ index: Int) {
                guard index < pending.count else { return }
                let asset = pending[index]
                group.addTask {
                    let result = await scanVisualTags(for: asset)
                    return (asset, result.needsOCR, result.visualTags, index)
                }
            }

            while nextIndex < min(workerCount, pending.count) {
                enqueue(nextIndex)
                nextIndex += 1
            }

            for await result in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                batchLock.lock()
                completed += 1
                if result.needsOCR {
                    ocrQueue.append(result.asset)
                    visualOnlyBatch.append((result.asset, result.visualTags))
                    if visualOnlyBatch.count >= 12 {
                        let flush = visualOnlyBatch
                        visualOnlyBatch.removeAll(keepingCapacity: true)
                        batchLock.unlock()
                        try? await PhotoSearchIndexStore.shared.updateVisualAnalyses(flush)
                    } else {
                        batchLock.unlock()
                    }
                } else {
                    skipBatch.append((result.asset, "", result.visualTags))
                    if skipBatch.count >= 12 {
                        let flush = skipBatch
                        skipBatch.removeAll(keepingCapacity: true)
                        batchLock.unlock()
                        try? await PhotoSearchIndexStore.shared.updateSearchAnalyses(flush)
                    } else {
                        batchLock.unlock()
                    }
                }

                if nextIndex < pending.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
        }

        batchLock.lock()
        let remainingSkip = skipBatch
        let remainingVisual = visualOnlyBatch
        batchLock.unlock()
        try? await PhotoSearchIndexStore.shared.updateSearchAnalyses(remainingSkip)
        try? await PhotoSearchIndexStore.shared.updateVisualAnalyses(remainingVisual)
        return ocrQueue
    }

    /// 阶段 2：仅 OCR 候选，720px
    nonisolated private static func indexOCRPass(for assets: [PHAsset]) async {
        var batch: [(asset: PHAsset, text: String)] = []
        batch.reserveCapacity(12)
        let batchLock = NSLock()
        var completed = 0

        await withTaskGroup(of: (asset: PHAsset, text: String, index: Int).self) { group in
            var nextIndex = 0
            let workerCount = max(1, SearchOCRSettings.indexConcurrency)

            func enqueue(_ index: Int) {
                guard index < assets.count else { return }
                let asset = assets[index]
                group.addTask {
                    let text = await recognizeSearchOCR(for: asset, index: index, total: assets.count)
                    return (asset, text, index)
                }
            }

            while nextIndex < min(workerCount, assets.count) {
                enqueue(nextIndex)
                nextIndex += 1
            }

            for await result in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                batchLock.lock()
                batch.append((result.asset, result.text))
                completed += 1
                let shouldFlush = batch.count >= 12
                let flushBatch = shouldFlush ? batch : nil
                if shouldFlush {
                    batch.removeAll(keepingCapacity: true)
                }
                batchLock.unlock()

                if let flushBatch {
                    try? await PhotoSearchIndexStore.shared.updateOCRTexts(
                        flushBatch.map { ($0.asset, $0.text) }
                    )
                }

                if nextIndex < assets.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }
        }

        batchLock.lock()
        let remaining = batch
        batchLock.unlock()
        try? await PhotoSearchIndexStore.shared.updateOCRTexts(remaining.map { ($0.asset, $0.text) })
#if DEBUG
        SearchOCRDebugLog.info("finished ocr \(completed)/\(assets.count)")
#endif
    }

    nonisolated private static func scanVisualTags(for asset: PHAsset) async -> (needsOCR: Bool, visualTags: [String]) {
        guard let probe = await requestSearchIndexImage(
            for: asset,
            maxEdge: SearchOCRSettings.maxImageProbeEdge
        ) else {
            return (false, [])
        }

        let classified = classificationTags(for: probe.cgImage)
        let gate = SearchOCRSettings.ocrGateDecision(
            classificationTags: classified,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            probeImage: probe.cgImage,
            probeOrientation: probe.orientation
        )
        let visualTags = indexVisualTags(from: probe.cgImage, classification: classified)
        return (gate.shouldRun, visualTags)
    }

    /// 索引用视觉 tag：整图主色 + 人物图才做人体检测与服装色
    nonisolated private static func indexVisualTags(
        from image: CGImage,
        classification: [String]? = nil
    ) -> [String] {
        let classified = classification ?? classificationTags(for: image)
        var tags = Set(SearchOCRSettings.lightweightVisualTags(from: classified))

        if let color = dominantColorTag(
            in: image,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        ) {
            tags.insert(color)
        }

        let suggestsPerson = SearchOCRSettings.classificationSuggestsPerson(classified)
        guard suggestsPerson else {
            return tags.sorted()
        }

        let humanRects = detectedHumanRects(in: image)
        if !humanRects.isEmpty {
            tags.formUnion(["person", "people", "human"])
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

    /// 阶段 3：有 OCR 文本的图送云端扩 tag
    nonisolated private static func indexTagEnrichmentPass(for assets: [PHAsset]) async {
        let batchSize = 8
        var index = 0
        var batchNumber = 0
        while index < assets.count {
            guard !Task.isCancelled else { return }
            let end = min(index + batchSize, assets.count)
            let batch = Array(assets[index..<end])
            index = end
            batchNumber += 1

            let payloads = await enrichmentPayloads(for: batch)
            guard !payloads.isEmpty else {
#if DEBUG
                SearchOCRDebugLog.info("[TagEnrich] batch \(batchNumber) skip empty payloads")
#endif
                continue
            }

#if DEBUG
            for payload in payloads {
                if let asset = batch.first(where: { $0.localIdentifier == payload.assetId }) {
                    SearchOCRDebugLog.logEnrichSubmit(asset: asset, ocrSnippet: payload.ocrSnippet)
                }
            }
            SearchOCRDebugLog.logEnrichBatchRequest(
                batch: batchNumber,
                count: payloads.count,
                assetIds: payloads.map(\.assetId)
            )
#endif
            let started = CFAbsoluteTimeGetCurrent()

            do {
                let results = try await TagEnrichmentClient.enrich(payloads: payloads)
#if DEBUG
                let durationMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                SearchOCRDebugLog.logEnrichBatchSuccess(
                    batch: batchNumber,
                    count: results.count,
                    durationMs: durationMs
                )
#endif
                let updates = results.compactMap { result -> (PHAsset, [String], [String], String)? in
                    guard let asset = batch.first(where: { $0.localIdentifier == result.assetId }) else {
                        return nil
                    }
#if DEBUG
                    SearchOCRDebugLog.logEnrichResult(
                        asset: asset,
                        enrichedTags: result.enrichedTags,
                        sensitiveTypes: result.sensitiveTypes,
                        searchDescription: result.searchDescription ?? ""
                    )
#endif
                    let description = result.searchDescription ?? ""
                    return (asset, result.enrichedTags, result.sensitiveTypes, description)
                }
                try? await PhotoSearchIndexStore.shared.updateEnrichedAnalyses(updates)
            } catch {
#if DEBUG
                SearchOCRDebugLog.logEnrichBatchFailed(batch: batchNumber, error: String(describing: error))
#endif
                await applyLocalEnrichmentFallback(for: batch)
            }
        }
    }

    nonisolated private static func enrichmentPayloads(
        for assets: [PHAsset]
    ) async -> [TagEnrichmentClient.Payload] {
        let entries = await PhotoSearchIndexStore.shared.validEntries(for: assets)
        return assets.compactMap { asset in
            guard let entry = entries[asset.localIdentifier],
                  let ocrText = entry.ocrText else {
                return nil
            }
            let snippet = String(ocrText.prefix(TagEnrichmentClient.ocrSnippetLimit))
            guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return TagEnrichmentClient.Payload(
                assetId: asset.localIdentifier,
                rawTags: entry.visualTags ?? [],
                ocrSnippet: snippet,
                mediaType: entry.mediaType,
                assetTypes: entry.assetTypes
            )
        }
    }

    nonisolated private static func applyLocalEnrichmentFallback(for assets: [PHAsset]) async {
#if DEBUG
        SearchOCRDebugLog.logEnrichFallback(count: assets.count)
#endif
        let entries = await PhotoSearchIndexStore.shared.validEntries(for: assets)
        var updates: [(PHAsset, [String])] = []
        updates.reserveCapacity(assets.count)
        for asset in assets {
            guard let entry = entries[asset.localIdentifier] else { continue }
            let sensitive = SensitiveTypeDetector.detect(
                ocrText: entry.ocrText,
                visualTags: entry.visualTags
            )
            updates.append((asset, sensitive))
        }
        try? await PhotoSearchIndexStore.shared.updateLocalSensitiveFallback(updates)
    }

    nonisolated private static func recognizeSearchOCR(
        for asset: PHAsset,
        index: Int = 0,
        total: Int = 1
    ) async -> String {
        guard let payload = await requestSearchIndexImage(
            for: asset,
            maxEdge: SearchOCRSettings.maxImageEdge
        ) else {
            return ""
        }

        let fastText = recognizeText(
            cgImage: payload.cgImage,
            orientation: payload.orientation,
            level: .fast
        ) ?? ""

        let ocrText: String
        let ocrMode: String
        if SearchOCRSettings.shouldRefineWithAccurate(fastText: fastText) {
            ocrText = recognizeText(
                cgImage: payload.cgImage,
                orientation: payload.orientation,
                level: .accurate
            ) ?? fastText
            ocrMode = "fast+accurate"
        } else if SearchOCRSettings.isUsefulSearchableOCR(fastText) {
            ocrText = fastText
            ocrMode = "fast"
        } else {
            ocrText = ""
            ocrMode = "skip-garbage"
        }

#if DEBUG
        let entries = await PhotoSearchIndexStore.shared.validEntries(for: [asset])
        let visualTags = entries[asset.localIdentifier]?.visualTags ?? []
        logSearchScanResult(
            index: index,
            total: total,
            asset: asset,
            ocrText: ocrText,
            visualTags: visualTags,
            imageLoaded: true,
            ocrMode: ocrMode
        )
#endif
        return ocrText
    }

    nonisolated private static func searchImageAnalysis(
        for asset: PHAsset,
        index: Int = 0,
        total: Int = 1
    ) async -> (ocrText: String, visualTags: [String]) {
        let scan = await scanVisualTags(for: asset)
        guard scan.needsOCR else {
            return ("", scan.visualTags)
        }
        let ocrText = await recognizeSearchOCR(for: asset, index: index, total: total)
        return (ocrText, scan.visualTags)
    }

#if DEBUG
    nonisolated private static func logSearchScanResult(
        index: Int,
        total: Int,
        asset: PHAsset,
        ocrText: String,
        visualTags: [String],
        imageLoaded: Bool,
        ocrMode: String
    ) {
        let sensitive = SensitiveTypeDetector.detect(ocrText: ocrText, visualTags: visualTags)
        let fields = sensitive.contains("id_card")
            ? IDCardFieldExtractor.extract(from: ocrText)
            : IDCardFieldExtractor.Fields()
        SearchOCRDebugLog.logScanResult(
            index: index,
            total: total,
            asset: asset,
            ocrText: ocrText,
            visualTagCount: visualTags.count,
            sensitiveTypes: sensitive,
            idCardName: fields.name,
            idCardNumber: fields.number,
            imageLoaded: imageLoaded,
            ocrMode: ocrMode
        )
    }
#endif

    private struct SearchOCRImagePayload {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    nonisolated private static func requestSearchIndexImage(
        for asset: PHAsset,
        maxEdge: Int
    ) async -> SearchOCRImagePayload? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = maxEdge <= SearchOCRSettings.maxImageProbeEdge
                ? .fastFormat
                : .highQualityFormat
            options.resizeMode = .fast
            options.isSynchronous = false

            let sourceEdge = max(asset.pixelWidth, asset.pixelHeight)
            let edge = min(sourceEdge, maxEdge)
            let targetSize = CGSize(width: edge, height: edge)

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                if cancelled || info?[PHImageErrorKey] != nil {
                    resumed = true
#if DEBUG
                    let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
                    let err = info?[PHImageErrorKey]
                    SearchOCRDebugLog.info(
                        "image load fail \(name) cancelled=\(cancelled) error=\(String(describing: err))"
                    )
#endif
                    continuation.resume(returning: nil)
                    return
                }
                if degraded { return }
                guard let image, let cgImage = image.cgImage else {
                    resumed = true
                    continuation.resume(returning: nil)
                    return
                }
                resumed = true
                continuation.resume(returning: SearchOCRImagePayload(
                    cgImage: cgImage,
                    orientation: SearchOCRSettings.visionOrientation(for: image)
                ))
            }
        }
    }

    nonisolated private static func requestSearchOCRImage(
        for asset: PHAsset
    ) async -> SearchOCRImagePayload? {
        await requestSearchIndexImage(for: asset, maxEdge: SearchOCRSettings.maxImageEdge)
    }

    nonisolated private static func recognizeText(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        level: VNRequestTextRecognitionLevel
    ) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        request.recognitionLanguages = SearchOCRSettings.recognitionLanguages()
        request.minimumTextHeight = level == .fast ? 0.012 : 0.008
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: orientation,
            options: [:]
        )
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
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 900, height: 900),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                let cancelled = info?[PHImageCancelledKey] as? Bool ?? false
                guard !cancelled else {
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                guard !resumed, !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
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
        indexVisualTags(from: image)
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
        let emptyAlbums = fetchEmptyAlbums()

        return LibrarySnapshot(
            imageAssets: imageAssets,
            videoAssets: videoAssets,
            screenshotAssets: screenshotAssets,
            livePhotoAssets: livePhotoAssets,
            largeVideoAssets: largeVideoAssets,
            screenRecordingAssets: screenRecordingAssets,
            monthGroups: monthGroups,
            mediaStorageBytes: imageStorageBytes + videoStorageBytes,
            videoStorageBytes: videoStorageBytes,
            screenshotStorageBytes: screenshotStorageBytes,
            livePhotoStorageBytes: livePhotoStorageBytes,
            largeVideoStorageBytes: largeVideoStorageBytes,
            screenRecordingStorageBytes: screenRecordingStorageBytes,
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
}

private actor SearchIndexRunCoordinator {
    static let shared = SearchIndexRunCoordinator()
    private var isRunning = false
    private var currentTask: Task<Void, Never>?

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
    }

    func start(force: Bool, operation: @escaping @Sendable () async -> Void) {
        if force {
            currentTask?.cancel()
            isRunning = false
        } else if isRunning {
            return
        }
        isRunning = true
        currentTask = Task.detached(priority: .utility) {
            await operation()
            await SearchIndexRunCoordinator.shared.finish()
        }
    }

    private func finish() {
        isRunning = false
        currentTask = nil
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
        .onAppear { loadThumbnail() }
        .onChange(of: asset.localIdentifier) { _, _ in
            loadThumbnail()
        }
        .onDisappear {
            if let requestID {
                library.cancelImageRequest(requestID)
                self.requestID = nil
            }
        }
    }

    private func loadThumbnail() {
        if let requestID {
            library.cancelImageRequest(requestID)
            self.requestID = nil
        }
        image = nil
        requestID = library.requestThumbnail(for: asset, targetSize: targetSize) {
            image = $0
        }
    }
}
