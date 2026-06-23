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

struct PhotoMonthGroup: Identifiable {
    let id: String
    let date: Date
    let assets: [PHAsset]
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
    @Published private(set) var similarGroups: [SimilarAssetGroup] = []
    @Published private(set) var duplicateScanProgress: (current: Int, total: Int)?
    @Published private(set) var scanState: ScanState = .idle
    @Published private(set) var analysisCacheSize: Int64 = 0

    let imageManager = PHCachingImageManager()

    private let fallbackShotInterval: TimeInterval = 3
    private let fallbackSequenceDuration: TimeInterval = 10
    private let similarityThreshold: Float = 0.34
    private let analysisCache = SimilarAnalysisCache()
    private let duplicateCache = DuplicateFingerprintCache()
    private let monthlyReviewStore = MonthlyReviewStore()
    private var scanTask: Task<Void, Never>?

    override init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
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

    func refreshLibrary() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            scanState = .loadingLibrary
            duplicateGroups = []
            similarGroups = []

            let assets = Self.fetchImageAssets()
            let videos = Self.fetchVideoAssets()
            photoCount = assets.count
            videoCount = videos.count
            screenshotAssets = Array(
                assets
                    .filter { $0.mediaSubtypes.contains(.photoScreenshot) }
                    .reversed()
            )
            screenshotCount = screenshotAssets.count
            videoAssets = Array(videos.reversed())
            largeVideoAssets = Array(
                videos
                    .filter { $0.duration >= 60 }
                    .reversed()
            )
            screenRecordingAssets = Array(
                videos
                    .filter { $0.mediaSubtypes.contains(.videoScreenRecording) }
                    .reversed()
            )
            monthGroups = Self.makeMonthGroups(from: assets)
            await restoreMonthlyReviewProgress()
            await scanDuplicates(in: assets)

            let candidates = Self.continuousShotCandidateGroups(
                assets: assets,
                maximumAdjacentInterval: fallbackShotInterval,
                maximumSequenceDuration: fallbackSequenceDuration
            )
            scanState = .analyzing(current: 0, total: candidates.count)

            var groups: [SimilarAssetGroup] = []
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
                    group = await analyze(candidate)
                    activeCache[signature] = Self.cacheGroup(
                        group,
                        signature: signature
                    )
                }

                if let group {
                    groups.append(group)
                    similarGroups = groups.sorted {
                        ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                    }
                }
                scanState = .analyzing(current: index + 1, total: candidates.count)
                await Task.yield()
            }
            try? await analysisCache.replace(with: activeCache)
            analysisCacheSize = await analysisCache.sizeInBytes() +
                duplicateCache.sizeInBytes()
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
        guard !group.assets.isEmpty else { return 1 }
        let availableIDs = Set(group.assets.map(\.localIdentifier))
        let reviewed = reviewedIDs(for: group.id).intersection(availableIDs)
        return Double(reviewed.count) / Double(availableIDs.count)
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
    }

    func clearAnalysisCache() {
        scanTask?.cancel()
        Task {
            try? await analysisCache.clear()
            try? await duplicateCache.clear()
            analysisCacheSize = 0
            scanState = .idle
        }
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

        duplicateGroups = assetsByFingerprint.values
            .filter { $0.count >= 2 }
            .map(Self.makeDuplicateGroup)
            .sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        try? await duplicateCache.replace(with: activeCache)
        duplicateScanProgress = nil
    }

    private func analyze(_ assets: [PHAsset]) async -> SimilarAssetGroup? {
        var analyzed: [AnalyzedAsset] = []

        for asset in assets {
            guard !Task.isCancelled,
                  let image = await requestAnalysisImage(for: asset),
                  let cgImage = image.cgImage else {
                continue
            }

            if let result = await Task.detached(priority: .utility, operation: { () -> AnalyzedAsset? in
                guard let feature = Self.featurePrint(for: cgImage) else { return nil }
                return AnalyzedAsset(
                    asset: asset,
                    feature: feature,
                    qualityScore: Self.qualityScore(for: cgImage, asset: asset)
                )
            }).value {
                analyzed.append(result)
            }
        }

        guard analyzed.count >= 2 else { return nil }
        let threshold = similarityThreshold
        let similar = await Task.detached(priority: .utility) {
            Self.largestConnectedGroup(analyzed, threshold: threshold)
        }.value
        guard similar.count >= 2 else { return nil }

        let bestID = similar.max(by: { $0.qualityScore < $1.qualityScore })?.asset.localIdentifier
        let results = similar.map {
            SimilarAsset(
                id: $0.asset.localIdentifier,
                asset: $0.asset,
                qualityScore: $0.qualityScore,
                isBest: $0.asset.localIdentifier == bestID
            )
        }

        return SimilarAssetGroup(
            id: results.map(\.id).sorted().joined(separator: "|"),
            assets: results,
            creationDate: results.compactMap(\.asset.creationDate).min()
        )
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

    private static func fetchImageAssets() -> [PHAsset] {
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

    private static func fetchCount(mediaType: PHAssetMediaType) -> Int {
        PHAsset.fetchAssets(with: mediaType, options: nil).count
    }

    private static func fetchVideoAssets() -> [PHAsset] {
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

    private static func makeMonthGroups(from assets: [PHAsset]) -> [PhotoMonthGroup] {
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
                    assets: Array(assets.reversed())
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

    private static func makeDuplicateGroup(_ assets: [PHAsset]) -> SimilarAssetGroup {
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

    private static func restoreGroup(
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

    private static func cacheGroup(
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

    private static func continuousShotCandidateGroups(
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

    nonisolated private static func featurePrint(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    nonisolated private static func largestConnectedGroup(
        _ assets: [AnalyzedAsset],
        threshold: Float
    ) -> [AnalyzedAsset] {
        var adjacency = Array(repeating: [Int](), count: assets.count)
        for left in assets.indices {
            for right in assets.indices where right > left {
                var distance: Float = .greatestFiniteMagnitude
                if (try? assets[left].feature.computeDistance(
                    &distance,
                    to: assets[right].feature
                )) != nil, distance <= threshold {
                    adjacency[left].append(right)
                    adjacency[right].append(left)
                }
            }
        }

        var visited = Set<Int>()
        var largest: [Int] = []
        for start in assets.indices where !visited.contains(start) {
            var queue = [start]
            var component: [Int] = []
            visited.insert(start)
            while let current = queue.popLast() {
                component.append(current)
                for next in adjacency[current] where !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
            if component.count > largest.count {
                largest = component
            }
        }
        return largest.map { assets[$0] }
    }

    nonisolated private static func qualityScore(for image: CGImage, asset: PHAsset) -> Double {
        let sharpness = edgeEnergy(for: image)
        let resolution = log2(Double(max(asset.pixelWidth * asset.pixelHeight, 1))) / 30
        let favoriteBonus = asset.isFavorite ? 0.08 : 0
        return sharpness * 0.72 + resolution * 0.28 + favoriteBonus
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
            self?.refreshLibrary()
        }
    }
}

private struct AnalyzedAsset {
    let asset: PHAsset
    let feature: VNFeaturePrintObservation
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
