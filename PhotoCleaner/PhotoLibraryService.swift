import CoreGraphics
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
    @Published private(set) var similarGroups: [SimilarAssetGroup] = []
    @Published private(set) var scanState: ScanState = .idle

    let imageManager = PHCachingImageManager()

    private let candidateInterval: TimeInterval = 5
    private let similarityThreshold: Float = 0.34
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

    func refreshLibrary() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            scanState = .loadingLibrary

            let assets = Self.fetchImageAssets()
            photoCount = assets.count
            videoCount = Self.fetchCount(mediaType: .video)
            screenshotCount = assets.reduce(into: 0) { count, asset in
                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    count += 1
                }
            }

            let candidates = Self.timeCandidateGroups(
                assets: assets,
                maximumInterval: candidateInterval
            )
            scanState = .analyzing(current: 0, total: candidates.count)

            var groups: [SimilarAssetGroup] = []
            for (index, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                if let group = await analyze(candidate) {
                    groups.append(group)
                    similarGroups = groups.sorted {
                        ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
                    }
                }
                scanState = .analyzing(current: index + 1, total: candidates.count)
                await Task.yield()
            }
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

    func deleteAssets(with identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(result)
        }
        refreshLibrary()
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

    private static func fetchImageAssets() -> [PHAsset] {
        let options = PHFetchOptions()
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

    private static func timeCandidateGroups(
        assets: [PHAsset],
        maximumInterval: TimeInterval
    ) -> [[PHAsset]] {
        var groups: [[PHAsset]] = []
        var current: [PHAsset] = []

        for asset in assets {
            guard let date = asset.creationDate else { continue }
            if let previousDate = current.last?.creationDate,
               date.timeIntervalSince(previousDate) <= maximumInterval {
                current.append(asset)
            } else {
                if current.count >= 2 {
                    groups.append(current)
                }
                current = [asset]
            }
        }
        if current.count >= 2 {
            groups.append(current)
        }
        return groups
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
