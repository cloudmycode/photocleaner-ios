import AVKit
import CoreLocation
import Photos
import PhotosUI
import Speech
import SwiftUI
import UIKit
import Vision

struct ContentView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var selectedTab: AppTab = .clean

    var body: some View {
        ZStack {
            if shouldShowInitialAnalysis {
                InitialAnalysisView()
                    .transition(.opacity)
            } else {
                mainTabs
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShowInitialAnalysis)
    }

    private var shouldShowInitialAnalysis: Bool {
        let hasAccess = library.authorizationStatus == .authorized ||
            library.authorizationStatus == .limited
        return hasAccess && !library.hasCompletedInitialAnalysis
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                QuickCleanView()
            }
            .tabBarSyncedWithNavigation()
            .tabItem { Label(String(localized: "tab.quick"), systemImage: "sparkles.rectangle.stack") }
            .tag(AppTab.clean)

            NavigationStack {
                AlbumsView()
            }
            .tabBarSyncedWithNavigation()
            .tabItem { Label(String(localized: "tab.albums"), systemImage: "photo.on.rectangle") }
            .tag(AppTab.albums)

            NavigationStack {
                SmartPhotoSearchView()
            }
            .tabBarSyncedWithNavigation()
            .tabItem { Label(String(localized: "tab.smart.search"), systemImage: "mic.badge.plus") }
            .tag(AppTab.compress)

            NavigationStack {
                SettingsView()
            }
            .tabBarSyncedWithNavigation()
            .tabItem { Label(String(localized: "tab.settings"), systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(.cleanerBlue)
    }
}

private enum AppTab {
    case clean
    case albums
    case compress
    case settings
}

private struct InitialAnalysisView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    private var progress: Double? {
        if let duplicateProgress = library.duplicateScanProgress,
           duplicateProgress.total > 0 {
            return Double(duplicateProgress.current) / Double(duplicateProgress.total)
        }
        if case let .analyzing(current, total) = library.scanState,
           total > 0 {
            return Double(current) / Double(total)
        }
        return nil
    }

    private var statusText: String {
        if case .loadingLibrary = library.scanState {
            return String(localized: "initial.analysis.reading")
        }
        if let duplicateProgress = library.duplicateScanProgress {
            return String.localizedStringWithFormat(
                String(localized: "duplicate.analyzing.format"),
                duplicateProgress.current,
                duplicateProgress.total
            )
        }
        if case let .analyzing(current, total) = library.scanState {
            return String.localizedStringWithFormat(
                String(localized: "burst.analyzing.format"),
                current,
                total
            )
        }
        return String(localized: "initial.analysis.preparing")
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Color.cleanerBlue)

            VStack(spacing: 10) {
                Text("initial.analysis.title")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("initial.analysis.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress)
                        .tint(.cleanerBlue)
                } else {
                    ProgressView()
                        .tint(.cleanerBlue)
                }
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 18)
            }
            .frame(maxWidth: 320)
            .padding(.top, 8)

            Spacer()

            Text("initial.analysis.cache.note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cleanerBackground.ignoresSafeArea())
    }
}

private func formattedStorage(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct QuickCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    private var photoItems: [CleanerCategory] {
        [
            CleanerCategory.duplicates(
                count: library.duplicateCandidateCount,
                size: formattedStorage(library.duplicateCandidateStorageBytes)
            ),
            CleanerCategory.bursts(
                count: library.burstCandidateCount,
                size: formattedStorage(library.burstCandidateStorageBytes)
            ),
            CleanerCategory.screenshots(
                count: library.screenshotCount,
                size: formattedStorage(library.screenshotStorageBytes)
            ),
            CleanerCategory.livePhotos(
                count: library.livePhotoCount,
                size: formattedStorage(library.livePhotoStorageBytes)
            )
        ]
    }

    private var videoItems: [CleanerCategory] {
        [
            CleanerCategory.allVideos(
                count: library.videoCount,
                size: formattedStorage(library.videoStorageBytes)
            ),
            CleanerCategory.largeVideos(
                count: library.largeVideoCount,
                size: formattedStorage(library.largeVideoStorageBytes)
            ),
            CleanerCategory.screenRecordings(
                count: library.screenRecordingCount,
                size: formattedStorage(library.screenRecordingStorageBytes)
            )
        ]
    }

    private var albumItems: [CleanerCategory] {
        [
            CleanerCategory.emptyAlbums(count: library.emptyAlbumCount)
        ]
    }

    private var formattedMediaStorage: String {
        formattedStorage(library.mediaStorageBytes)
    }

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "app.name"))
            if hasPhotoAccess {
                StorageCard(
                    label: String(localized: "media.storage"),
                    value: formattedMediaStorage,
                    description: String.localizedStringWithFormat(
                        String(localized: "library.summary.format"),
                        library.photoCount,
                        library.videoCount
                    )
                )

                CleanerSection(title: String(localized: "section.photos")) {
                    ForEach(photoItems) { item in
                        let loadingText = loadingText(for: item)
                        if canOpen(item) {
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                CategoryRow(item: item, loadingText: loadingText)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                showLoadingToast()
                            } label: {
                                CategoryRow(item: item, loadingText: loadingText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                CleanerSection(title: String(localized: "section.videos")) {
                    ForEach(videoItems) { item in
                        let loadingText = loadingText(for: item)
                        if canOpen(item) {
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                CategoryRow(item: item, loadingText: loadingText)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                showLoadingToast()
                            } label: {
                                CategoryRow(item: item, loadingText: loadingText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                CleanerSection(title: String(localized: "section.albums")) {
                    ForEach(albumItems) { item in
                        NavigationLink {
                            EmptyAlbumCleanView()
                        } label: {
                            CategoryRow(item: item, loadingText: nil)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(scanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.cleanerBlue)
                    Text("photo.access.required")
                        .font(.headline)
                    Text("photo.access.description")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("open.settings") {
                        library.openAppSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            }
        }
        .background(Color.cleanerBackground)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                CleanerToast(message: toastMessage)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animatedTabBarVisible()
    }

    @ViewBuilder
    private func destination(for item: CleanerCategory) -> some View {
        if item.kind == .duplicate {
            SimilarCleanView(mode: .duplicate)
        } else if item.kind == .burst {
            SimilarCleanView(mode: .burst)
        } else if item.kind == .livePhoto {
            LivePhotoCleanView(category: item)
        } else if item.kind.usesAssetGrid {
            AssetGridCleanView(category: item)
        } else {
            AssetSwipeCleanView(category: item)
        }
    }

    private func loadingText(for item: CleanerCategory) -> String? {
        guard !library.isUsingCachedHomeSummary else { return nil }

        if case .loadingLibrary = library.scanState {
            return String(localized: "library.reading")
        }

        if item.kind == .duplicate,
           let progress = library.duplicateScanProgress {
            return String.localizedStringWithFormat(
                String(localized: "duplicate.analyzing.format"),
                progress.current,
                progress.total
            )
        }

        if item.kind == .burst {
            if library.duplicateScanProgress != nil {
                return String(localized: "home.item.loading")
            }
            if case let .analyzing(current, total) = library.scanState,
               current < total {
                return String.localizedStringWithFormat(
                    String(localized: "burst.analyzing.format"),
                    current,
                    total
                )
            }
        }

        return nil
    }

    private func canOpen(_ item: CleanerCategory) -> Bool {
        switch item.kind {
        case .duplicate:
            return library.hasDuplicateScanResults || library.duplicateScanProgress == nil
        case .burst:
            if library.hasCompletedInitialAnalysis { return true }
            if library.duplicateScanProgress != nil { return false }
            if case let .analyzing(current, total) = library.scanState {
                return current >= total
            }
            return true
        default:
            return true
        }
    }

    private func showLoadingToast() {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            toastMessage = String(localized: "home.item.loading.toast")
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toastMessage = nil
                }
            }
        }
    }

    private var scanStatus: String {
        switch library.authorizationStatus {
        case .denied, .restricted:
            return String(localized: "photo.access.required")
        case .notDetermined:
            return String(localized: "photo.access.requesting")
        default:
            if library.isUsingCachedHomeSummary {
                return String(localized: "analysis.complete")
            }
            if case .loadingLibrary = library.scanState {
                return String(localized: "library.reading")
            }
            if let progress = library.duplicateScanProgress {
                return String.localizedStringWithFormat(
                    String(localized: "duplicate.analyzing.format"),
                    progress.current,
                    progress.total
                )
            }
            if case let .analyzing(current, total) = library.scanState {
                return String.localizedStringWithFormat(
                    String(localized: "burst.analyzing.format"),
                    current,
                    total
                )
            }
            return String(localized: "analysis.complete")
        }
    }

    private var hasPhotoAccess: Bool {
        library.authorizationStatus == .authorized ||
            library.authorizationStatus == .limited
    }
}

struct AlbumsView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    private var yearGroups: [PhotoYearGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: library.monthGroups) {
            calendar.component(.year, from: $0.date)
        }
        return grouped
            .map { year, months in
                PhotoYearGroup(
                    year: year,
                    months: months.sorted { $0.date > $1.date }
                )
            }
            .sorted { $0.year > $1.year }
    }

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "tab.albums"))
            StorageCard(
                label: String(localized: "total.photos"),
                value: "\(library.photoCount)",
                description: String(localized: "total.photos.description")
            )

            if library.monthGroups.isEmpty {
                Text("library.reading")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
            } else {
                ForEach(yearGroups) { yearGroup in
                    CleanerSection(title: String(yearGroup.year)) {
                        ForEach(yearGroup.months) { month in
                            NavigationLink {
                                MonthlyReviewView(
                                    monthID: month.id,
                                    title: month.date.formatted(.dateTime.year().month(.wide)),
                                    assets: month.assets
                                )
                            } label: {
                                MonthAssetRow(group: month)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .background(Color.cleanerBackground)
        .animatedTabBarVisible()
    }
}

private struct PhotoYearGroup: Identifiable {
    var id: Int { year }
    let year: Int
    let months: [PhotoMonthGroup]
}

private struct MonthReviewAction {
    let id: String
    let markedForDeletion: Bool
}

struct MonthlyReviewView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let monthID: String
    let title: String
    let assets: [PHAsset]

    @State private var reviewedIDs = Set<String>()
    @State private var markedIDs = Set<String>()
    @State private var removedIDs = Set<String>()
    @State private var history: [MonthReviewAction] = []
    @State private var offset: CGSize = .zero
    @State private var isZoomed = false
    @State private var zoomReset = 0
    @State private var isExitingCard = false
    @State private var lockedStackAsset: PHAsset?
    @State private var suppressStackedPreview = false
    @State private var frontCardScale: CGFloat = 1
    @State private var frontCardOffsetY: CGFloat = 0
    @State private var frontCardOpacity: Double = 1
    @State private var promotedAsset: PHAsset?
    @State private var showDeleteConfirmation = false
    @State private var deletionError: String?
    @State private var previewAsset: IdentifiablePHAsset?

    private var availableAssets: [PHAsset] {
        assets.filter { !removedIDs.contains($0.localIdentifier) }
    }

    private var currentAsset: PHAsset? {
        availableAssets.first { !reviewedIDs.contains($0.localIdentifier) }
    }

    private var nextAsset: PHAsset? {
        guard let currentAsset,
              let currentIndex = availableAssets.firstIndex(where: {
                  $0.localIdentifier == currentAsset.localIdentifier
              })
        else { return nil }

        return availableAssets[(currentIndex + 1)...].first {
            !reviewedIDs.contains($0.localIdentifier)
        }
    }

    private var reviewedCount: Int {
        reviewedIDs.intersection(Set(availableAssets.map(\.localIdentifier))).count
    }

    private var deckAsset: PHAsset? {
        promotedAsset ?? currentAsset
    }

    var body: some View {
        Group {
            if let asset = deckAsset {
                VStack(spacing: 0) {
                    reviewToolbar
                        .padding(.top, 16)

                    GeometryReader { geo in
                        reviewDeck(asset, containerSize: geo.size)
                    }
                    .padding(.horizontal, 22)

                    HStack(spacing: 36) {
                        ActionCircle(systemName: "arrow.up", tint: .cleanerGreen) {
                            flyOutAndReview(asset, markForDeletion: false)
                        }
                        .accessibilityLabel(Text("keep"))

                        ActionCircle(systemName: "trash", tint: .red) {
                            flyOutAndReview(asset, markForDeletion: true)
                        }
                        .accessibilityLabel(Text("mark.for.deletion"))
                    }
                    .padding(.vertical, 16)
                }
            } else {
                ContentUnavailableView(
                    "month.review.complete",
                    systemImage: "checkmark.circle",
                    description: Text("month.review.complete.description")
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !markedIDs.isEmpty {
                markedPhotosBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .animatedTabBarHidden()
        .background(Color.cleanerBackground)
        .confirmationDialog(
            "month.delete.confirm.title",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("month.delete.confirm.action", role: .destructive) {
                deleteMarkedPhotos()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "month.delete.confirm.message"),
                    markedIDs.count
                )
            )
        }
        .alert("delete.failed", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .onAppear {
            library.restoreMonthlyReviewProgressIfNeeded()
            syncReviewState()
        }
        .onChange(of: library.reviewedIDs(for: monthID)) {
            syncReviewState()
        }
        .onChange(of: library.markedIDs(for: monthID)) {
            syncReviewState()
        }
        .assetPreview($previewAsset, assets: availableAssets)
    }

    private func syncReviewState() {
        guard !isExitingCard, !suppressStackedPreview, promotedAsset == nil else { return }
        reviewedIDs = library.reviewedIDs(for: monthID)
        markedIDs = library.markedIDs(for: monthID)
    }

    private var reviewToolbar: some View {
        HStack {
            Text("\(min(reviewedCount + 1, availableAssets.count))/\(availableAssets.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("undo") {
                undo()
            }
            .font(.subheadline.weight(.semibold))
            .disabled(history.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func stackedAsset(behind asset: PHAsset) -> PHAsset? {
        if isExitingCard {
            return lockedStackAsset
        }
        guard !suppressStackedPreview else { return nil }
        return nextAsset
    }

    private func reviewDeck(_ asset: PHAsset, containerSize: CGSize) -> some View {
        ZStack {
            if let backAsset = stackedAsset(behind: asset),
               backAsset.localIdentifier != asset.localIdentifier {
                stackedPreviewCard(backAsset, containerSize: containerSize)
                    .scaleEffect(0.96)
                    .offset(y: 18)
                    .opacity(0.88)
                    .allowsHitTesting(false)
            }

            reviewCard(asset, containerSize: containerSize)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    private func monthlyPhotoSize(for asset: PHAsset, in container: CGSize) -> CGSize {
        let width = max(container.width, 1)
        let aspect: CGFloat
        if asset.pixelWidth > 0, asset.pixelHeight > 0 {
            aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        } else {
            aspect = 1
        }
        let height = min(width / aspect, max(container.height, 1))
        return CGSize(width: width, height: height)
    }

    @ViewBuilder
    private func stackedPreviewCard(_ asset: PHAsset, containerSize: CGSize) -> some View {
        let photoSize = monthlyPhotoSize(for: asset, in: containerSize)
        PhotoThumbnailView(
            asset: asset,
            targetSize: CGSize(width: 880, height: 1100)
        )
        .id(asset.localIdentifier)
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.cleanerBorder.opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
        .frame(width: containerSize.width, height: containerSize.height)
    }

    @ViewBuilder
    private func reviewCard(_ asset: PHAsset, containerSize: CGSize) -> some View {
        let photoSize = monthlyPhotoSize(for: asset, in: containerSize)
        ZStack(alignment: .topLeading) {
            ZoomableScrollView(isZoomed: $isZoomed, resetTrigger: zoomReset) {
                PhotoThumbnailView(
                    asset: asset,
                    targetSize: CGSize(width: 880, height: 1100)
                )
                .id(asset.localIdentifier)
            }
            .frame(width: photoSize.width, height: photoSize.height)
        }
        .frame(width: photoSize.width, height: photoSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .assetPreviewSource(id: asset.localIdentifier)
        .overlay {
            if !isZoomed, offset.height > 30 {
                swipeBadge(
                    title: String(localized: "mark.for.deletion"),
                    systemName: "trash",
                    color: .red,
                    alignment: .bottom
                )
            } else if !isZoomed, offset.height < -30 {
                swipeBadge(
                    title: String(localized: "keep"),
                    systemName: "arrow.up",
                    color: .cleanerGreen,
                    alignment: .top
                )
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .scaleEffect(frontCardScale)
        .opacity(frontCardOpacity)
        .offset(x: offset.width, y: offset.height + frontCardOffsetY)
        .frame(width: containerSize.width, height: containerSize.height)
        .simultaneousGesture(monthlyDragGesture(for: asset, containerHeight: containerSize.height))
        .onTapGesture {
            guard !isZoomed, !isExitingCard else { return }
            previewAsset = IdentifiablePHAsset(asset: asset)
        }
        .onChange(of: asset.localIdentifier) { _, _ in
            Task { @MainActor in
                resetPhotoTransform(animated: false)
            }
        }
    }

    private func monthlyDragGesture(for asset: PHAsset, containerHeight: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isZoomed, !isExitingCard else { return }
                offset = CGSize(width: 0, height: value.translation.height)
            }
            .onEnded { value in
                guard !isZoomed, !isExitingCard else {
                    return
                }
                if value.translation.height > 110 {
                    flyOutAndReview(asset, markForDeletion: true, containerHeight: containerHeight)
                } else if value.translation.height < -110 {
                    flyOutAndReview(asset, markForDeletion: false, containerHeight: containerHeight)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        offset = .zero
                    }
                }
            }
    }

    private func flyOutAndReview(
        _ asset: PHAsset,
        markForDeletion: Bool,
        containerHeight: CGFloat? = nil
    ) {
        guard !isExitingCard, promotedAsset == nil else { return }
        let promoted = nextAsset
        let shouldPromote = promoted != nil
        lockedStackAsset = promoted
        isExitingCard = true
        let distance = (containerHeight ?? 640) * 1.35
        let targetY: CGFloat = markForDeletion ? distance : -distance
        withAnimation(.easeIn(duration: 0.28)) {
            offset = CGSize(width: 0, height: targetY)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                review(asset, markForDeletion: markForDeletion)
                if shouldPromote {
                    promotedAsset = promoted
                }
                offset = .zero
                isExitingCard = false
                lockedStackAsset = nil
                suppressStackedPreview = shouldPromote
                if shouldPromote {
                    frontCardScale = 0.96
                    frontCardOffsetY = 18
                    frontCardOpacity = 0.88
                } else {
                    frontCardScale = 1
                    frontCardOffsetY = 0
                    frontCardOpacity = 1
                }
            }
            if shouldPromote {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    frontCardScale = 1
                    frontCardOffsetY = 0
                    frontCardOpacity = 1
                }
                try? await Task.sleep(for: .milliseconds(420))
                suppressStackedPreview = false
                promotedAsset = nil
            }
        }
    }

    private func swipeBadge(
        title: String,
        systemName: String,
        color: Color,
        alignment: Alignment
    ) -> some View {
        Label(title, systemImage: systemName)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(16)
    }

    private var markedPhotosBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "month.marked.format"),
                        markedIDs.count
                    )
                )
                .font(.subheadline.bold())
                Text("month.marked.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red, in: Circle())
            }
            .accessibilityLabel(Text("month.delete.marked"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private func review(_ asset: PHAsset, markForDeletion: Bool) {
        let id = asset.localIdentifier
        history.append(MonthReviewAction(id: id, markedForDeletion: markForDeletion))
        reviewedIDs.insert(id)
        library.setMonthlyAsset(
            id,
            reviewed: true,
            markedForDeletion: markForDeletion,
            monthID: monthID
        )
        if markForDeletion {
            markedIDs.insert(id)
        }
        zoomReset += 1
        isZoomed = false
    }

    private func undo() {
        guard let action = history.popLast() else { return }
        promotedAsset = nil
        reviewedIDs.remove(action.id)
        library.setMonthlyAsset(action.id, reviewed: false, monthID: monthID)
        if action.markedForDeletion {
            markedIDs.remove(action.id)
        }
        resetPhotoTransform(animated: true)
    }

    private func deleteMarkedPhotos() {
        let identifiers = markedIDs
        Task {
            do {
                try await library.deleteAssets(with: identifiers)
                identifiers.forEach {
                    library.setMonthlyAsset(
                        $0,
                        reviewed: false,
                        monthID: monthID
                    )
                }
                removedIDs.formUnion(identifiers)
                reviewedIDs.subtract(identifiers)
                markedIDs.subtract(identifiers)
                history.removeAll { identifiers.contains($0.id) }
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }

    private func resetPhotoTransform(animated: Bool) {
        let reset = {
            zoomReset += 1
            isZoomed = false
            offset = .zero
            frontCardScale = 1
            frontCardOffsetY = 0
            frontCardOpacity = 1
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                reset()
            }
        } else {
            reset()
        }
    }
}

private struct MonthAssetRow: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let group: PhotoMonthGroup

    private var progress: Double {
        library.monthlyProgress[group.id] ?? 0
    }

    private var reviewedCount: Int {
        library.monthlyReviewedCounts[group.id] ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            if let first = group.assets.first {
                PhotoThumbnailView(
                    asset: first,
                    targetSize: CGSize(width: 112, height: 112)
                )
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(group.date.formatted(.dateTime.month(.wide)))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if progress >= 1 {
                        Label("month.progress.complete", systemImage: "checkmark")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.cleanerGreen)
                    } else {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "month.progress.format"),
                                reviewedCount,
                                group.assets.count
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress)
                    .tint(progress >= 1 ? .cleanerGreen : .cleanerBlue)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "items.count.format"),
                        group.assets.count
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedStorage(group.storageBytes))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.cleanerText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 88)
        .background(.white)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 92)
        }
    }
}

enum PhotoGroupCleanMode {
    case duplicate
    case burst
}

struct SimilarCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let mode: PhotoGroupCleanMode
    @State private var selectedIDs = Set<String>()
    @State private var previewPhoto: IdentifiablePHAsset?
    @State private var deletionError: String?
    @State private var showDeleteConfirmation = false

    private var selectedCount: Int { selectedIDs.count }
    private var expectedCandidateCount: Int {
        switch mode {
        case .duplicate:
            return library.duplicateCandidateCount
        case .burst:
            return library.burstCandidateCount
        }
    }

    private var groups: [SimilarAssetGroup] {
        switch mode {
        case .duplicate:
            return library.duplicateGroups
        case .burst:
            return library.burstGroups
        }
    }

    private var previewAssets: [PHAsset] {
        groups.flatMap(\.assets).map(\.asset)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(titleKey)
                            .font(.title2.bold())
                        Spacer()
                        Text(keptKey)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.cleanerGreen.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.cleanerGreen)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(titleKey)
                            .font(.title2.bold())
                        Text(keptKey)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.cleanerGreen)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

                similarContent
            }
            .padding(.bottom, selectedCount > 0 ? 104 : 16)
        }
        .overlay(alignment: .bottomTrailing) {
            if selectedCount > 0 {
                similarDeleteButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.08), value: selectedCount > 0)
        .navigationBarTitleDisplayMode(.inline)
        .animatedTabBarHidden()
        .assetPreview(
            $previewPhoto,
            assets: previewAssets,
            isSelected: { selectedIDs.contains($0) }
        ) { wrapped in
            if selectedIDs.contains(wrapped.id) {
                selectedIDs.remove(wrapped.id)
            } else {
                selectedIDs.insert(wrapped.id)
            }
        }
        .alert("delete.failed", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .confirmationDialog(
            "month.delete.confirm.title",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("month.delete.confirm.action", role: .destructive) {
                deleteSelected()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "month.delete.confirm.message"),
                selectedCount
            ))
        }
        .onChange(of: groups.map(\.id)) {
            selectNonBestPhotos()
            preheatGroupThumbnails()
        }
        .onAppear {
            restoreCachedGroupsIfNeeded()
            selectNonBestPhotos()
            preheatGroupThumbnails()
        }
        .background(Color.cleanerBackground)
    }

    private var similarDeleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: 10) {
                Text(String.localizedStringWithFormat(
                    String(localized: "month.marked.format"),
                    selectedCount
                ))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Image(systemName: "trash.fill")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color.red, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        }
        .accessibilityLabel(Text("month.delete.marked"))
    }

    @ViewBuilder
    private var similarContent: some View {
        switch library.authorizationStatus {
        case .denied, .restricted:
            ContentUnavailableView(
                "photo.access.required",
                systemImage: "photo.badge.exclamationmark",
                description: Text("photo.access.description")
            )
            .padding(.top, 60)
        default:
            if groups.isEmpty {
                if expectedCandidateCount > 0 {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(scanDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if library.scanState == .finished || library.hasCompletedInitialAnalysis {
                    ContentUnavailableView(
                        emptyTitleKey,
                        systemImage: "checkmark.circle",
                        description: Text(emptyDescriptionKey)
                    )
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(scanDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(groups.indices, id: \.self) { index in
                        let group = groups[index]
                        SimilarGroup(
                            title: groupTitle(group, index: index),
                            mode: mode,
                            group: group,
                            selectedIDs: $selectedIDs,
                            previewPhoto: $previewPhoto
                        )
                    }
                }
            }
        }
    }

    private var scanDescription: String {
        if mode == .duplicate,
           let progress = library.duplicateScanProgress {
            return String.localizedStringWithFormat(
                String(localized: "duplicate.analyzing.format"),
                progress.current,
                progress.total
            )
        }
        if case let .analyzing(current, total) = library.scanState {
            return String.localizedStringWithFormat(
                String(localized: "burst.analyzing.format"),
                current,
                total
            )
        }
        return String(localized: "library.reading")
    }

    private func groupTitle(_ group: SimilarAssetGroup, index: Int) -> String {
        guard let date = group.creationDate else {
            return String.localizedStringWithFormat(
                String(localized: "group.number.format"),
                index + 1
            )
        }
        if mode == .burst {
            return String.localizedStringWithFormat(
                String(localized: "burst.group.title.format"),
                date.formatted(date: .abbreviated, time: .shortened),
                group.assets.count
            )
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func selectNonBestPhotos() {
        let available = Set(groups.flatMap(\.assets).map(\.id))
        selectedIDs.formIntersection(available)
        if selectedIDs.isEmpty {
            selectedIDs = Set(
                groups
                    .flatMap(\.assets)
                    .filter { !$0.isBest }
                    .map(\.id)
            )
        }
    }

    private func preheatGroupThumbnails() {
        let assets = Array(
            groups
                .flatMap(\.assets)
                .map(\.asset)
                .prefix(24)
        )
        library.preheatThumbnails(
            for: assets,
            targetSize: CGSize(width: 132, height: 146)
        )
    }

    private func restoreCachedGroupsIfNeeded() {
        switch mode {
        case .duplicate:
            library.restoreCachedDuplicateGroupsIfNeeded()
        case .burst:
            library.restoreCachedBurstGroupsIfNeeded()
        }
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.title"
        case .burst:
            return "burst.title"
        }
    }

    private var keptKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.original.kept"
        case .burst:
            return "burst.best.pick"
        }
    }

    private var emptyTitleKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.empty"
        case .burst:
            return "burst.empty"
        }
    }

    private var emptyDescriptionKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.empty.description"
        case .burst:
            return "burst.empty.description"
        }
    }

    private func toggle(_ photo: SimilarAsset) {
        if selectedIDs.contains(photo.id) {
            selectedIDs.remove(photo.id)
        } else {
            selectedIDs.insert(photo.id)
        }
    }

    private func deleteSelected() {
        let identifiers = selectedIDs
        Task {
            do {
                try await library.deleteAssets(with: identifiers)
                selectedIDs.subtract(identifiers)
            } catch {
                deletionError = error.localizedDescription
            }
        }
    }
}

struct AssetSwipeCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let category: CleanerCategory

    @State private var offset: CGSize = .zero
    @State private var showInfo = false
    @State private var excludedIDs = Set<String>()
    @State private var markedIDs = Set<String>()
    @State private var history: [ReviewAction] = []
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var operationError: String?
    @State private var showDeleteConfirmation = false
    @State private var previewAsset: IdentifiablePHAsset?

    private var sourceAssets: [PHAsset] {
        switch category.kind {
        case .screenshot:
            return library.screenshotAssets
        case .video:
            return library.videoAssets
        case .largeVideo:
            return library.largeVideoAssets
        case .recording:
            return library.screenRecordingAssets
        default:
            return []
        }
    }

    private var currentAsset: PHAsset? {
        sourceAssets.first { !excludedIDs.contains($0.localIdentifier) }
    }

    private var expectedCount: Int {
        switch category.kind {
        case .screenshot:
            return library.screenshotCount
        case .video:
            return library.videoCount
        case .largeVideo:
            return library.largeVideoCount
        case .recording:
            return library.screenRecordingCount
        default:
            return category.count
        }
    }

    var body: some View {
        Group {
            if let asset = currentAsset {
                ScrollView {
                    VStack(spacing: 0) {
                        toolbar
                        photoCard(asset)
                        if showInfo {
                            assetInfo(asset)
                        }
                        Color.clear.frame(height: 20)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if !markedIDs.isEmpty {
                            markedSummaryBar
                        }
                        actionBar(asset)
                    }
                }
            } else if sourceAssets.isEmpty && expectedCount > 0 {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("library.reading")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ContentUnavailableView(
                        "cleanup.complete",
                        systemImage: "checkmark.circle",
                        description: Text("cleanup.complete.description")
                    )
                    if !markedIDs.isEmpty {
                        markedSummaryBar
                    }
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .animatedTabBarHidden()
        .background(Color.cleanerBackground)
        .onAppear {
            library.restoreMediaAssetsIfNeeded()
        }
        .assetPreview($previewAsset, assets: sourceAssets)
        .alert("operation.failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(
            "month.delete.confirm.title",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("month.delete.confirm.action", role: .destructive) {
                deleteMarked()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "month.delete.confirm.message"),
                markedIDs.count
            ))
        }
    }

    private var toolbar: some View {
        HStack {
            Text("\(min(excludedIDs.count + 1, sourceAssets.count))/\(sourceAssets.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("undo") {
                undo()
            }
            .font(.subheadline.weight(.semibold))
            .disabled(history.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func photoCard(_ asset: PHAsset) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
                InteractiveVideoPreview(asset: asset)
                    .id(asset.localIdentifier)
                    .assetPreviewSource(id: asset.localIdentifier)
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: 440)
                    .aspectRatio(0.84, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                    .onTapGesture { previewAsset = IdentifiablePHAsset(asset: asset) }
            } else {
                PhotoThumbnailView(
                    asset: asset,
                    targetSize: CGSize(width: 880, height: 1100)
                )
                .assetPreviewSource(id: asset.localIdentifier)
                .id(asset.localIdentifier)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: 440)
                .aspectRatio(0.84, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 18)))
                .onTapGesture { previewAsset = IdentifiablePHAsset(asset: asset) }
                .gesture(
                    DragGesture()
                        .onChanged { offset = $0.translation }
                        .onEnded { value in
                            if value.translation.width < -110 {
                                markForDeletion(asset)
                            } else if value.translation.width > 110 {
                                keep(asset)
                            }
                            offset = .zero
                        }
                )
            }

            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(18)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
    }

    private func assetInfo(_ asset: PHAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "-",
                systemImage: "calendar"
            )
            Label(
                "\(asset.pixelWidth) x \(asset.pixelHeight)",
                systemImage: "photo"
            )
            if asset.location != nil {
                Label("location.available", systemImage: "location")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    private func actionBar(_ asset: PHAsset) -> some View {
        HStack(spacing: 14) {
            ActionCircle(systemName: "trash", tint: .red) {
                markForDeletion(asset)
            }
            ActionCircle(
                systemName: isFavorite(asset) ? "heart.fill" : "heart",
                tint: .pink
            ) {
                toggleFavorite(asset)
            }
            Button("keep") {
                keep(asset)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
    }

    private var markedSummaryBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String.localizedStringWithFormat(
                    String(localized: "month.marked.format"),
                    markedIDs.count
                ))
                .font(.subheadline.weight(.bold))
                Text("month.marked.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.red, in: Circle())
            }
            .accessibilityLabel(Text("month.delete.marked"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func keep(_ asset: PHAsset) {
        let id = asset.localIdentifier
        history.append(.kept(id))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            _ = excludedIDs.insert(id)
        }
    }

    private func markForDeletion(_ asset: PHAsset) {
        let id = asset.localIdentifier
        history.append(.marked(id))
        markedIDs.insert(id)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            _ = excludedIDs.insert(id)
        }
    }

    private func deleteMarked() {
        let identifiers = markedIDs
        Task {
            do {
                try await library.deleteAssets(with: identifiers)
                markedIDs.subtract(identifiers)
                history.removeAll { identifiers.contains($0.identifier) }
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func undo() {
        guard let action = history.popLast() else { return }
        excludedIDs.remove(action.identifier)
        if case .marked = action {
            markedIDs.remove(action.identifier)
        }
    }

    private func isFavorite(_ asset: PHAsset) -> Bool {
        favoriteOverrides[asset.localIdentifier] ?? asset.isFavorite
    }

    private func toggleFavorite(_ asset: PHAsset) {
        let newValue = !isFavorite(asset)
        favoriteOverrides[asset.localIdentifier] = newValue
        Task {
            do {
                try await library.setFavorite(newValue, for: asset)
            } catch {
                favoriteOverrides[asset.localIdentifier] = asset.isFavorite
                operationError = error.localizedDescription
            }
        }
    }
}

struct AssetGridCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let category: CleanerCategory

    @State private var selectedIDs = Set<String>()
    @State private var removedIDs = Set<String>()
    @State private var showDeleteConfirmation = false
    @State private var operationError: String?
    @State private var previewAsset: IdentifiablePHAsset?

    private var sourceAssets: [PHAsset] {
        switch category.kind {
        case .screenshot:
            library.screenshotAssets
        case .video:
            library.videoAssets
        case .largeVideo:
            library.largeVideoAssets
        case .recording:
            library.screenRecordingAssets
        default:
            []
        }
    }

    private var assets: [PHAsset] {
        sourceAssets.filter { !removedIDs.contains($0.localIdentifier) }
    }

    private var expectedCount: Int {
        switch category.kind {
        case .screenshot:
            library.screenshotCount
        case .video:
            library.videoAssets.count
        case .largeVideo:
            library.largeVideoAssets.count
        case .recording:
            library.screenRecordingAssets.count
        default:
            category.count
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    private var showsVideoBadge: Bool {
        category.kind == .video || category.kind == .largeVideo || category.kind == .recording
    }

    var body: some View {
        let base: some View = contentView
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if allSelected { selectedIDs.removeAll() }
                        else { selectedIDs.formUnion(Set(assets.map(\.localIdentifier))) }
                    } label: {
                        Text(allSelected ? "select.none" : "select.all")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.cleanerBlue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animatedTabBarHidden()
            .background(Color.cleanerBackground)

        return base
            .overlay(alignment: .bottomTrailing) {
                if !selectedIDs.isEmpty {
                    selectedDeleteButton
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.08), value: !selectedIDs.isEmpty)
            .assetPreview(
                $previewAsset,
                assets: assets,
                isSelected: { selectedIDs.contains($0) },
                onToggle: { item in toggleSelection(item.asset) }
            )
            .confirmationDialog(
                "month.delete.confirm.title",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("month.delete.confirm.action", role: .destructive) {
                    deleteSelected()
                }
                Button("cancel", role: .cancel) {}
            } message: {
                Text(String.localizedStringWithFormat(
                    String(localized: "month.delete.confirm.message"),
                    selectedIDs.count
                ))
            }
            .alert("operation.failed", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
            .onChange(of: sourceAssets.map(\.localIdentifier)) {
                let available = Set(sourceAssets.map(\.localIdentifier))
                selectedIDs = selectedIDs.intersection(available)
                removedIDs = removedIDs.intersection(available)
            }
            .onAppear {
                library.restoreMediaAssetsIfNeeded()
            }
    }

    @ViewBuilder
    private var contentView: some View {
        Group {
            if assets.isEmpty {
                if expectedCount > 0 {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("library.reading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "cleanup.complete",
                        systemImage: "checkmark.circle",
                        description: Text("cleanup.complete.description")
                    )
                }
            } else {
                gridView
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    AssetGridItem(
                        asset: asset,
                        isSelected: selectedIDs.contains(asset.localIdentifier),
                        storageText: formattedStorage(library.storageBytes(for: asset)),
                        showsVideoBadge: showsVideoBadge,
                        onToggle: { toggleSelection(asset) },
                        onPreview: {
                            previewAsset = IdentifiablePHAsset(asset: asset)
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .padding(.bottom, selectedIDs.isEmpty ? 24 : 104)
        }
    }

    private var selectedDeleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: 10) {
                Text(String.localizedStringWithFormat(
                    String(localized: "month.marked.format"),
                    selectedIDs.count
                ))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Image(systemName: "trash.fill")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color.red, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        }
        .accessibilityLabel(Text("month.delete.marked"))
    }

    private var allSelected: Bool {
        !assets.isEmpty && Set(assets.map(\.localIdentifier)).isSubset(of: selectedIDs)
    }

    private func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func deleteSelected() {
        let identifiers = selectedIDs
        Task {
            do {
                try await library.deleteAssets(with: identifiers)
                removedIDs.formUnion(identifiers)
                selectedIDs.subtract(identifiers)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

struct LivePhotoCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let category: CleanerCategory

    @State private var selectedIDs = Set<String>()
    @State private var removedIDs = Set<String>()
    @State private var showConfirmation = false
    @State private var operationError: String?
    @State private var previewAsset: IdentifiablePHAsset?
    @State private var recommendedIDs = Set<String>()
    @State private var isLoadingRecommendations = false
    @State private var recommendationTask: Task<Void, Never>?

    private var assets: [PHAsset] {
        library.livePhotoAssets.filter { !removedIDs.contains($0.localIdentifier) }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    var body: some View {
        Group {
            if assets.isEmpty {
                if library.livePhotoCount > 0 {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("library.reading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "live.cleanup.empty",
                        systemImage: "livephoto",
                        description: Text("live.cleanup.empty.description")
                    )
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            AssetGridItem(
                                asset: asset,
                                isSelected: selectedIDs.contains(asset.localIdentifier),
                                storageText: liveStorageText(for: asset),
                                showsVideoBadge: false,
                                onToggle: { toggleSelection(asset) },
                                onPreview: { previewAsset = IdentifiablePHAsset(asset: asset) }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                    .padding(.bottom, selectedIDs.isEmpty ? 24 : 104)
                }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if selectedIDs.isEmpty {
                        selectedIDs = recommendedIDs
                    } else {
                        selectedIDs.removeAll()
                    }
                } label: {
                    Text(selectedIDs.isEmpty ? "live.select.recommended" : "select.none")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cleanerBlue)
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty && recommendedIDs.isEmpty && isLoadingRecommendations)
            }
        }
        .animatedTabBarHidden()
        .background(Color.cleanerBackground)
        .overlay(alignment: .bottomTrailing) {
            if !selectedIDs.isEmpty {
                convertButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.08), value: !selectedIDs.isEmpty)
        .assetPreview(
            $previewAsset,
            assets: assets,
            isSelected: { selectedIDs.contains($0) },
            onToggle: { item in toggleSelection(item.asset) }
        )
        .confirmationDialog(
            "live.convert.confirm.title",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("live.convert.confirm.action", role: .destructive) {
                convertSelected()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(String.localizedStringWithFormat(
                String(localized: "live.convert.confirm.message"),
                selectedIDs.count
            ))
        }
        .alert("operation.failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .onAppear {
            library.restoreMediaAssetsIfNeeded()
            startRecommendationAnalysis()
        }
        .onDisappear {
            recommendationTask?.cancel()
            recommendationTask = nil
        }
        .onChange(of: library.livePhotoAssets.map(\.localIdentifier)) {
            let available = Set(assets.map(\.localIdentifier))
            selectedIDs = selectedIDs.intersection(available)
            removedIDs = removedIDs.intersection(available)
            recommendedIDs = recommendedIDs.intersection(available)
            startRecommendationAnalysis()
        }
    }

    private var convertButton: some View {
        Button {
            showConfirmation = true
        } label: {
            HStack(spacing: 10) {
                Text(String.localizedStringWithFormat(
                    String(localized: "live.convert.selected.format"),
                    selectedIDs.count
                ))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Image(systemName: "livephoto.slash")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color.cleanerBlue, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        }
    }

    private func liveStorageText(for asset: PHAsset) -> String {
        let motionBytes = library.liveMotionBytes(for: asset)
        if motionBytes > 0 {
            return formattedStorage(motionBytes)
        }
        return formattedStorage(library.storageBytes(for: asset))
    }

    private func startRecommendationAnalysis() {
        recommendationTask?.cancel()
        let analysisAssets = assets
        guard !analysisAssets.isEmpty else {
            recommendedIDs = []
            isLoadingRecommendations = false
            return
        }

        isLoadingRecommendations = true
        recommendationTask = Task {
            let ids = await library.recommendedLivePhotoSlimmingIDs(for: analysisAssets)
            guard !Task.isCancelled else { return }
            let available = Set(assets.map(\.localIdentifier))
            recommendedIDs = ids.intersection(available)
            isLoadingRecommendations = false
        }
    }

    private func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func convertSelected() {
        let identifiers = selectedIDs
        Task {
            do {
                try await library.convertLivePhotosToStill(with: identifiers)
                removedIDs.formUnion(identifiers)
                selectedIDs.subtract(identifiers)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

private struct AssetGridItem: View {
    let asset: PHAsset
    let isSelected: Bool
    let storageText: String
    let showsVideoBadge: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                PhotoThumbnailView(
                    asset: asset,
                    targetSize: CGSize(width: 320, height: 320)
                )
                .assetPreviewSource(id: asset.localIdentifier)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()

                if showsVideoBadge {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.5), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                }

                selectionButton
                    .padding(6)

                HStack {
                    storageBadge
                    Spacer(minLength: 0)
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .background(Color.cleanerCard)
            .clipShape(Rectangle())
            .overlay {
                Rectangle()
                    .stroke(Color.cleanerBorder, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPreview)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var storageBadge: some View {
        Text(storageText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.black.opacity(0.52), in: Capsule())
    }

    private var selectionButton: some View {
        Button(action: onToggle) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isSelected ? .white : .white.opacity(0.92),
                    isSelected ? Color.cleanerBlue : .black.opacity(0.35)
                )
                .frame(width: 34, height: 34)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isSelected ? "unselect" : "select"))
    }
}

private enum ReviewAction {
    case kept(String)
    case marked(String)

    var identifier: String {
        switch self {
        case let .kept(identifier), let .marked(identifier):
            return identifier
        }
    }
}

private struct InteractiveVideoPreview: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let asset: PHAsset

    @State private var isZoomed = false
    @State private var zoomReset = 0
    @StateObject private var playback = VideoPlaybackController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            ZoomableScrollView(isZoomed: $isZoomed, resetTrigger: zoomReset) {
                VideoPreviewSurface(asset: asset, controller: playback)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }
}

@MainActor
final class VideoPlaybackController: ObservableObject {
    @Published var player: AVPlayer?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isScrubbing = false
    @Published private(set) var isFrameReady = false

    private var requestID: PHImageRequestID?
    private var timeObserver: Any?
    private weak var timeObserverPlayer: AVPlayer?
    private var itemStatusObservation: NSKeyValueObservation?
    private var pendingAutoplay = false
    private(set) var loadedAssetID: String?

    func isReady(for assetID: String) -> Bool {
        loadedAssetID == assetID && player != nil
    }

    func requestPlay(asset: PHAsset, library: PhotoLibraryService) {
        let assetID = asset.localIdentifier
        if loadedAssetID == assetID {
            if let player {
                if !isPlaying {
                    togglePlayback()
                }
                return
            }
            pendingAutoplay = true
            return
        }
        pendingAutoplay = true
        load(asset: asset, library: library)
    }

    func load(asset: PHAsset, library: PhotoLibraryService) {
        guard loadedAssetID != asset.localIdentifier else { return }
        teardown(library: library, keepPendingAutoplay: true)
        let assetID = asset.localIdentifier
        loadedAssetID = assetID
        duration = 0
        currentTime = 0
        isFrameReady = false
        requestID = library.requestPlayerItem(for: asset) { [weak self] item in
            guard let self, let item, loadedAssetID == assetID else { return }
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite, itemDuration > 0 {
                duration = itemDuration
            }
            observeFrameReady(for: item)
            addTimeObserver(to: newPlayer)
            if !pendingAutoplay {
                isPlaying = false
            }
        }
    }

    func teardown(library: PhotoLibraryService, keepPendingAutoplay: Bool = false) {
        if !keepPendingAutoplay {
            pendingAutoplay = false
        }
        player?.pause()
        removeTimeObserver()
        itemStatusObservation = nil
        isFrameReady = false
        player = nil
        if let requestID {
            library.cancelImageRequest(requestID)
        }
        self.requestID = nil
        loadedAssetID = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        isScrubbing = false
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.1 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func observeFrameReady(for item: AVPlayerItem) {
        itemStatusObservation = nil
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item.status == .readyToPlay else { return }
                self.isFrameReady = true
                self.beginPlaybackIfPending()
            }
        }
    }

    private func beginPlaybackIfPending() {
        guard pendingAutoplay, let player else { return }
        pendingAutoplay = false
        player.play()
        isPlaying = true
    }

    private func removeTimeObserver() {
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        timeObserverPlayer = nil
    }

    private func addTimeObserver(to player: AVPlayer) {
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, let player, self.player === player, !isScrubbing else { return }
            currentTime = time.seconds.isFinite ? time.seconds : 0
            isPlaying = player.timeControlStatus == .playing
            if let itemDuration = player.currentItem?.duration.seconds,
               itemDuration.isFinite,
               itemDuration > 0 {
                duration = itemDuration
            }
        }
        timeObserverPlayer = player
    }
}

struct VideoPreviewControlsBar: View {
    @ObservedObject var controller: VideoPlaybackController
    var layout: Layout = .photos

    enum Layout {
        case photos
        case stacked
    }

    var body: some View {
        Group {
            switch layout {
            case .photos:
                photosLayout
            case .stacked:
                stackedLayout
            }
        }
    }

    private var photosLayout: some View {
        HStack(spacing: 10) {
            Text(formatTime(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(minWidth: 42, alignment: .leading)

            Slider(
                value: sliderBinding,
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: handleScrubbing
            )
            .tint(.white)

            Text(formatTime(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(minWidth: 42, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var stackedLayout: some View {
        VStack(spacing: 8) {
            Slider(
                value: sliderBinding,
                in: 0...max(controller.duration, 0.1),
                onEditingChanged: handleScrubbing
            )
            .tint(.white)
            HStack {
                Text(formatTime(controller.currentTime))
                Spacer()
                Text(formatTime(controller.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { controller.currentTime },
            set: { newValue in
                controller.currentTime = newValue
                controller.isScrubbing = true
            }
        )
    }

    private func handleScrubbing(_ editing: Bool) {
        controller.isScrubbing = editing
        guard !editing, let player = controller.player else { return }
        player.seek(to: CMTime(seconds: controller.currentTime, preferredTimescale: 600))
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = max(Int(value.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct VideoPreviewSurface: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let asset: PHAsset
    @ObservedObject var controller: VideoPlaybackController
    var showsInlineControls: Bool = true
    var isActive: Bool = true

    private var managesPlayback: Bool { showsInlineControls }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            videoPlaceholder

            if isActive,
               controller.loadedAssetID == asset.localIdentifier,
               let player = controller.player {
                VideoPlayer(player: player)
                    .opacity(controller.isFrameReady ? 1 : 0)
                    .animation(.easeIn(duration: 0.18), value: controller.isFrameReady)
            }

            if isActive {
                Button {
                    controller.requestPlay(asset: asset, library: library)
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showsInlineControls, isActive, controller.isFrameReady {
                VideoPreviewControlsBar(controller: controller, layout: .stacked)
                    .padding(12)
            }
        }
        .onAppear {
            guard managesPlayback else { return }
            controller.load(asset: asset, library: library)
        }
        .onChange(of: asset.localIdentifier) { _, _ in
            guard managesPlayback else { return }
            controller.load(asset: asset, library: library)
        }
        .onDisappear {
            guard managesPlayback else { return }
            controller.teardown(library: library)
        }
    }

    private var videoPlaceholder: some View {
        ZStack {
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 880, height: 1100)
            )
            Image(systemName: "play.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.42), in: Circle())
        }
    }
}

private struct AssetPreviewVideoContent: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let asset: PHAsset
    let isActive: Bool
    @ObservedObject var controller: VideoPlaybackController

    private var showsPlayer: Bool {
        isActive
            && controller.loadedAssetID == asset.localIdentifier
            && controller.player != nil
    }

    var body: some View {
        ZStack {
            Color.black
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 880, height: 1100)
            )

            if showsPlayer, let player = controller.player {
                VideoPlayer(player: player)
                    .opacity(controller.isFrameReady && controller.isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.15), value: controller.isFrameReady && controller.isPlaying)
            }

            if isActive {
                Button {
                    controller.requestPlay(asset: asset, library: library)
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.black.opacity(0.42), in: Circle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct LivePhotoPreview: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let asset: PHAsset
    let targetSize: CGSize

    @State private var livePhoto: PHLivePhoto?
    @State private var requestID: PHImageRequestID?
    @State private var playTrigger = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let livePhoto {
                LivePhotoSurface(livePhoto: livePhoto, playTrigger: playTrigger)
            } else {
                PhotoThumbnailView(asset: asset, targetSize: targetSize)
            }

            Label("LIVE", systemImage: "livephoto")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(10)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.18) {
            playTrigger += 1
        }
        .onAppear {
            guard livePhoto == nil else { return }
            requestID = library.requestLivePhoto(
                for: asset,
                targetSize: targetSize
            ) { result in
                livePhoto = result
            }
        }
        .onDisappear {
            if let requestID {
                library.cancelImageRequest(requestID)
            }
        }
    }
}

private struct LivePhotoSurface: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let playTrigger: Int

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.livePhoto = livePhoto
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
        if context.coordinator.lastPlayTrigger != playTrigger {
            context.coordinator.lastPlayTrigger = playTrigger
            view.startPlayback(with: .full)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastPlayTrigger = 0
    }
}

extension View {
    func assetPreview(
        _ item: Binding<IdentifiablePHAsset?>,
        assets: [PHAsset] = [],
        isSelected: @escaping (String) -> Bool = { _ in false },
        onToggle: @escaping (IdentifiablePHAsset) -> Void = { _ in }
    ) -> some View {
        AssetPreviewHost(
            item: item,
            assets: assets,
            isSelected: isSelected,
            onToggle: onToggle,
            content: { self }
        )
    }

    func assetPreviewSource(id: String) -> some View {
        modifier(AssetPreviewSourceModifier(id: id))
    }
}

private struct AssetPreviewNamespaceKey: EnvironmentKey {
    static var defaultValue: Namespace.ID? { nil }
}

private extension EnvironmentValues {
    var assetPreviewNamespace: Namespace.ID? {
        get { self[AssetPreviewNamespaceKey.self] }
        set { self[AssetPreviewNamespaceKey.self] = newValue }
    }
}

private struct AssetPreviewSourceModifier: ViewModifier {
    @Environment(\.assetPreviewNamespace) private var namespace
    let id: String

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct AssetPreviewHost<Content: View>: View {
    @Binding var item: IdentifiablePHAsset?
    let assets: [PHAsset]
    let isSelected: (String) -> Bool
    let onToggle: (IdentifiablePHAsset) -> Void
    @ViewBuilder let content: () -> Content
    @Namespace private var previewNamespace
    @State private var activeSourceID = ""

    var body: some View {
        content()
            .environment(\.assetPreviewNamespace, previewNamespace)
            .navigationDestination(item: $item) { wrapped in
                AssetPreviewView(
                    asset: wrapped.asset,
                    assets: assets,
                    onClose: { item = nil },
                    isSelected: isSelected,
                    onToggle: { onToggle(IdentifiablePHAsset(asset: $0)) },
                    onTransitionSourceChange: { activeSourceID = $0 }
                )
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .toolbar(.hidden, for: .bottomBar)
                .background(TabBarVisibilityAnimator(isHidden: true).frame(width: 0, height: 0))
                .navigationTransition(.zoom(sourceID: activeSourceID, in: previewNamespace))
                .onAppear {
                    activeSourceID = wrapped.id
                }
            }
            .background(TabBarVisibilityAnimator(isHidden: item != nil).frame(width: 0, height: 0))
            .onChange(of: item?.id) { _, newID in
                if newID == nil {
                    activeSourceID = ""
                }
            }
    }
}

struct AssetPreviewView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let assets: [PHAsset]
    @State private var displayedAsset: PHAsset
    var onClose: () -> Void = {}
    var isSelected: (String) -> Bool = { _ in false }
    var onToggle: (PHAsset) -> Void = { _ in }
    var onTransitionSourceChange: ((String) -> Void)? = nil

    init(
        asset: PHAsset,
        assets: [PHAsset] = [],
        onClose: @escaping () -> Void = {},
        isSelected: @escaping (String) -> Bool = { _ in false },
        onToggle: @escaping (PHAsset) -> Void = { _ in },
        onTransitionSourceChange: ((String) -> Void)? = nil
    ) {
        let resolvedAssets = assets.isEmpty ? [asset] : assets
        self.assets = resolvedAssets
        let index = resolvedAssets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) ?? 0
        _currentIndex = State(initialValue: index)
        _displayedAsset = State(initialValue: asset)
        self.onClose = onClose
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.onTransitionSourceChange = onTransitionSourceChange
    }

    @State private var currentIndex: Int
    @State private var isZoomed = false
    @State private var zoomReset = 0
    @State private var showDetail = true
    @State private var isDetailBarPresented = false
    @State private var locationDescription: String = "-"
    @State private var storageDescription: String = "-"
    @StateObject private var videoPlayback = VideoPlaybackController()

    private static let border: CGFloat = 20
    private static let detailPanelHeight: CGFloat = 120

    private var displayedIsSelected: Bool {
        isSelected(displayedAsset.localIdentifier)
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            Group {
                if assets.count > 1 {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                            previewPage(for: asset, isActive: index == currentIndex)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .background(TabViewPagingDisabler(isDisabled: isZoomed))
                } else {
                    previewPage(for: displayedAsset)
                }
            }
            .ignoresSafeArea()

            if displayedAsset.mediaType == .video,
               videoPlayback.isReady(for: displayedAsset.localIdentifier) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 88)
                    .allowsHitTesting(false)
                    VideoPreviewControlsBar(controller: videoPlayback, layout: .photos)
                        .padding(.bottom, 6)
                }
            }

            detailOverlay

            VStack {
                HStack {
                    Spacer()
                    previewSelectionButton
                        .padding(.trailing, 16)
                }
                .padding(.top, 12)
                Spacer()
            }
        }
        .background(Color.black)
        .onAppear {
            isDetailBarPresented = true
            onTransitionSourceChange?(displayedAsset.localIdentifier)
            preheatAdjacentThumbnails(around: currentIndex)
        }
        .onDisappear {
            videoPlayback.teardown(library: library)
        }
        .onChange(of: currentIndex) { _, index in
            guard assets.indices.contains(index) else { return }
            displayedAsset = assets[index]
            onTransitionSourceChange?(displayedAsset.localIdentifier)
            zoomReset += 1
            isZoomed = false
            showDetail = true
            isDetailBarPresented = true
            videoPlayback.teardown(library: library)
            preheatAdjacentThumbnails(around: index)
        }
        .task(id: displayedAsset.localIdentifier) {
            guard showDetail else { return }
            await loadDetailMetadata()
        }
        .onChange(of: showDetail) { _, isShown in
            guard isShown else { return }
            Task { await loadDetailMetadata() }
        }
    }

    private var previewSelectionButton: some View {
        Button {
            onToggle(displayedAsset)
        } label: {
            Image(systemName: displayedIsSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    displayedIsSelected ? .white : .white.opacity(0.92),
                    displayedIsSelected ? Color.cleanerBlue : .black.opacity(0.35)
                )
                .frame(width: 34, height: 34)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(displayedIsSelected ? "unselect" : "select"))
    }

    private var detailOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
                .allowsHitTesting(false)
            ZStack(alignment: .bottomLeading) {
                if showDetail, isDetailBarPresented {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.detailPanelHeight)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if showDetail, isDetailBarPresented {
                        detailTextOverlay
                            .transition(.opacity)
                    }
                    if isDetailBarPresented {
                        detailButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea()
    }

    private func previewPage(for asset: PHAsset, isActive: Bool = true) -> some View {
        GeometryReader { geo in
            let fitted = mediaFittedSize(for: asset, in: geo.size)
            ZoomableScrollView(
                isZoomed: isActive ? $isZoomed : .constant(false),
                resetTrigger: isActive ? zoomReset : 0
            ) {
                mediaContent(for: asset, isActive: isActive)
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isActive else { return }
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func mediaContent(for asset: PHAsset, isActive: Bool = true) -> some View {
        if asset.mediaType == .video {
            AssetPreviewVideoContent(
                asset: asset,
                isActive: isActive,
                controller: videoPlayback
            )
        } else if asset.mediaSubtypes.contains(.photoLive) {
            LivePhotoPreview(
                asset: asset,
                targetSize: CGSize(width: 1080, height: 1080)
            )
        } else {
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 1080, height: 1080)
            )
        }
    }

    private var detailButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showDetail.toggle()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(showDetail ? "hide.detail" : "show.detail"))
    }

    private var detailTextOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                displayedAsset.creationDate?
                    .formatted(date: .abbreviated, time: .shortened) ?? "-"
            )
            Text("\(displayedAsset.pixelWidth) × \(displayedAsset.pixelHeight) · \(storageDescription)")
            Text(locationDescription)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }

    private func mediaFittedSize(for asset: PHAsset, in container: CGSize) -> CGSize {
        let maxW = max(container.width - Self.border * 2, 1)
        let maxH = max(container.height - Self.border * 2, 1)
        let aspect: CGFloat
        if asset.pixelWidth > 0, asset.pixelHeight > 0 {
            aspect = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        } else {
            aspect = 1
        }
        if aspect >= 1 {
            let w = maxW
            let h = w / aspect
            return h <= maxH
                ? CGSize(width: w, height: h)
                : CGSize(width: maxH * aspect, height: maxH)
        } else {
            let h = maxH
            let w = h * aspect
            return w <= maxW
                ? CGSize(width: w, height: h)
                : CGSize(width: maxW, height: maxW / aspect)
        }
    }

    private func dismiss() {
        onClose()
    }

    private func preheatAdjacentThumbnails(around index: Int) {
        let indices = [index - 1, index, index + 1].filter { assets.indices.contains($0) }
        let nearbyAssets = indices.map { assets[$0] }
        guard !nearbyAssets.isEmpty else { return }
        library.preheatThumbnails(
            for: nearbyAssets,
            targetSize: CGSize(width: 880, height: 1100)
        )
    }

    @MainActor
    private func loadDetailMetadata() async {
        storageDescription = formattedStorage(library.storageBytes(for: displayedAsset))
        guard let location = displayedAsset.location else {
            locationDescription = "-"
            return
        }
        locationDescription = await Self.locationDescription(for: location)
    }

    private static func locationDescription(for location: CLLocation) async -> String {
        let coordinateText = String(
            format: "%.5f, %.5f",
            location.coordinate.latitude,
            location.coordinate.longitude
        )
        do {
            let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first
            let parts = [
                placemark?.name,
                placemark?.subLocality,
                placemark?.locality,
                placemark?.administrativeArea,
                placemark?.country
            ]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            var uniqueParts: [String] = []
            for part in parts where !uniqueParts.contains(part) {
                uniqueParts.append(part)
            }
            return uniqueParts.isEmpty ? coordinateText : uniqueParts.joined(separator: ", ")
        } catch {
            return coordinateText
        }
    }
}

private struct TabViewPagingDisabler: UIViewRepresentable {
    var isDisabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.apply(isDisabled: isDisabled, from: uiView)
    }

    final class Coordinator {
        weak var pagingScrollView: UIScrollView?

        func apply(isDisabled: Bool, from anchor: UIView) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.pagingScrollView == nil {
                    self.pagingScrollView = Self.findPagingScrollView(from: anchor)
                }
                self.pagingScrollView?.isScrollEnabled = !isDisabled
            }
        }

        private static func findPagingScrollView(from view: UIView) -> UIScrollView? {
            var root = view
            while let superview = root.superview {
                root = superview
            }
            return searchPagingScrollView(in: root)
        }

        private static func searchPagingScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView, scrollView.isPagingEnabled {
                return scrollView
            }
            for subview in view.subviews {
                if let found = searchPagingScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}

struct VideoCompressView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    private var categories: [CleanerCategory] {
        [
            CleanerCategory.allVideos(count: library.videoAssets.count),
            CleanerCategory.largeVideos(count: library.largeVideoAssets.count),
            CleanerCategory.screenRecordings(count: library.screenRecordingAssets.count)
        ]
    }

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "tab.compress"))
            StorageCard(
                label: String(localized: "section.videos"),
                value: "\(library.videoCount)",
                description: String(localized: "compress.summary.description")
            )

            CleanerSection(title: String(localized: "section.videos")) {
                ForEach(categories) { category in
                    NavigationLink {
                        AssetGridCleanView(category: category)
                    } label: {
                        CategoryRow(item: category, loadingText: nil)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("video.cleanup.footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 28)
        }
        .background(Color.cleanerBackground)
        .animatedTabBarVisible()
    }
}

struct SmartPhotoSearchView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @StateObject private var speech = PhotoSearchSpeechInput()

    @State private var queryText = ""
    @State private var results: [PHAsset] = []
    @State private var isParsing = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var previewAsset: IdentifiablePHAsset?
    @State private var didStartPress = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CleanerHeader(title: String(localized: "tab.smart.search"))
                    .padding(.top, 18)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                }

                resultsContent
            }
            .padding(.bottom, 96)
        }
        .background(Color.cleanerBackground)
        .safeAreaInset(edge: .bottom) {
            searchInputBar
        }
        .animatedTabBarVisible()
        .assetPreview($previewAsset, assets: results)
        .onChange(of: speech.transcript) {
            queryText = speech.transcript
        }
        .alert("smart.search.network.title", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        CleanerSection(title: resultsTitle) {
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("smart.search.searching")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.cleanerBlue)
                    Text(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "smart.search.empty.idle" : "smart.search.empty.results")
                        .font(.subheadline.weight(.semibold))
                    Text("smart.search.empty.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                    spacing: 2
                ) {
                    ForEach(results, id: \.localIdentifier) { asset in
                        AssetGridItem(
                            asset: asset,
                            isSelected: false,
                            storageText: formattedStorage(library.storageBytes(for: asset)),
                            showsVideoBadge: asset.mediaType == .video,
                            onToggle: {},
                            onPreview: { previewAsset = IdentifiablePHAsset(asset: asset) }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 20)
            }
        }
    }

    private var searchInputBar: some View {
        VStack(spacing: 8) {
            if speech.isRecording {
                Text("smart.search.listening")
                    .font(.caption)
                    .foregroundStyle(Color.cleanerBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                holdToSpeakButton

                TextField("smart.search.placeholder", text: $queryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 46)
                    .background(Color.cleanerCard, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cleanerBorder, lineWidth: 1)
                    }

                searchButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.cleanerBorder.opacity(0.8))
                .frame(height: 0.5)
        }
    }

    private var searchButton: some View {
        Button {
            submitQuery(queryText)
        } label: {
            ZStack {
                if isParsing || isSearching {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.headline.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing || isSearching)
        .opacity(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
        .accessibilityLabel(Text("smart.search.start"))
    }

    private var resultsTitle: String {
        if results.isEmpty {
            return String(localized: "smart.search.results")
        }
        return String.localizedStringWithFormat(
            String(localized: "smart.search.results.format"),
            results.count
        )
    }

    private var holdToSpeakButton: some View {
        Button {} label: {
            Image(systemName: speech.isRecording ? "waveform" : "mic.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(speech.isRecording ? Color.red : Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 8))
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !didStartPress else { return }
                    didStartPress = true
                    errorMessage = nil
                    queryText = ""
                    speech.start()
                }
                .onEnded { _ in
                    didStartPress = false
                    speech.stop()
                    let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !spoken.isEmpty {
                        queryText = spoken
                        submitQuery(spoken)
                    }
                }
        )
        .accessibilityLabel(Text("smart.search.hold.to.speak"))
    }

    private func submitQuery(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isParsing, !isSearching else { return }
        errorMessage = nil
        results = []
        isParsing = true
        isSearching = true
        Task {
            do {
                results = try await SmartSearchService.search(query: text)
                isParsing = false
                isSearching = false
            } catch {
                isParsing = false
                isSearching = false
                errorMessage = String(localized: "smart.search.network.unavailable")
            }
        }
    }
}

private final class PhotoSearchSpeechInput: NSObject, ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.current.identifier))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else { return }
                self?.startRecording()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
    }

    private func startRecording() {
        task?.cancel()
        task = nil
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            isRecording = false
            return
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self?.stop()
                }
            }
        }
    }
}

struct EmptyAlbumCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var deletionError: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteID: String?
    @State private var pendingDeleteTitle: String?

    var body: some View {
        Group {
            if library.emptyAlbums.isEmpty {
                if library.emptyAlbumCount > 0 {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("library.reading")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Empty Albums",
                        systemImage: "folder",
                        description: Text("All albums contain at least one item.")
                    )
                }
            } else {
                List {
                    ForEach(library.emptyAlbums, id: \.id) { album in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                    .font(.subheadline.weight(.semibold))
                                Text("Empty")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                pendingDeleteID = album.id
                                pendingDeleteTitle = album.title
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(String(localized: "category.empty.albums"))
        .navigationBarTitleDisplayMode(.inline)
        .animatedTabBarHidden()
        .background(Color.cleanerBackground)
        .onAppear {
            library.restoreEmptyAlbumsIfNeeded()
        }
        .confirmationDialog(
            "Delete Album?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let id = pendingDeleteID else { return }
                Task {
                    do {
                        try await library.deleteEmptyAlbum(with: id)
                    } catch {
                        deletionError = error.localizedDescription
                    }
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(pendingDeleteTitle.map { "\"\($0)\" will be deleted." } ?? "")
        }
        .alert("delete.failed", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var showCacheConfirmation = false
    @State private var isExportingSearchIndex = false
    @State private var exportedSearchIndexURL: URL?
    @State private var exportErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CleanerHeader(title: String(localized: "tab.settings"))

                SettingsGroup(title: String(localized: "settings.general.security")) {
                    Button {
                        library.openAppSettings()
                    } label: {
                        SettingsActionRow(
                            title: String(localized: "settings.photo.access"),
                            value: authorizationDescription,
                            systemImage: "photo"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        showCacheConfirmation = true
                    } label: {
                        SettingsActionRow(
                            title: String(localized: "settings.clear.cache"),
                            value: formattedCacheSize,
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        exportSmartSearchIndex()
                    } label: {
                        SettingsActionRow(
                            title: String(localized: "settings.smart.search.export"),
                            value: exportStatusText,
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExportingSearchIndex)
                }

                SettingsGroup(title: String(localized: "settings.support")) {
                    InfoPair(title: String(localized: "settings.version"), value: "1.0.0 (26)")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }

                Text("Smart Cleaner\n2026")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(.bottom, 28)
        }
        .background(Color.cleanerBackground)
        .confirmationDialog(
            "settings.clear.cache.confirm.title",
            isPresented: $showCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("settings.clear.cache.confirm.action", role: .destructive) {
                library.clearAnalysisCache()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("settings.clear.cache.confirm.message")
        }
        .sheet(
            isPresented: Binding(
                get: { exportedSearchIndexURL != nil },
                set: { if !$0 { exportedSearchIndexURL = nil } }
            )
        ) {
            if let exportedSearchIndexURL {
                ActivityView(activityItems: [exportedSearchIndexURL])
            }
        }
        .alert(
            "settings.smart.search.export.failed.title",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
        .animatedTabBarVisible()
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(
            fromByteCount: library.analysisCacheSize,
            countStyle: .file
        )
    }

    private var authorizationDescription: String {
        switch library.authorizationStatus {
        case .authorized:
            return String(localized: "settings.photo.access.full")
        case .limited:
            return String(localized: "settings.photo.access.limited")
        default:
            return String(localized: "settings.photo.access.none")
        }
    }

    private var exportStatusText: String {
        isExportingSearchIndex
            ? String(localized: "settings.smart.search.export.in.progress")
            : String(localized: "settings.smart.search.export.value")
    }

    private func exportSmartSearchIndex() {
        Task {
            isExportingSearchIndex = true
            defer { isExportingSearchIndex = false }

            do {
                exportedSearchIndexURL = try await library.exportSmartSearchDebugIndex()
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct CleanerScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                content
            }
            .padding(.bottom, 24)
        }
    }
}

private extension View {
    func animatedTabBarVisible() -> some View {
        background(TabBarVisibilityAnimator(isHidden: false).frame(width: 0, height: 0))
    }

    func animatedTabBarHidden() -> some View {
        background(TabBarVisibilityAnimator(isHidden: true).frame(width: 0, height: 0))
    }

    func tabBarSyncedWithNavigation() -> some View {
        background(TabBarNavigationSync().frame(width: 0, height: 0))
    }
}

private struct TabBarVisibilityAnimator: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> TabBarVisibilityController {
        TabBarVisibilityController()
    }

    func updateUIViewController(_ controller: TabBarVisibilityController, context: Context) {
        controller.setTabBarHidden(isHidden, animated: true)
    }

    static func dismantleUIViewController(_ controller: TabBarVisibilityController, coordinator: ()) {
        controller.setTabBarHidden(false, animated: true)
    }
}

private struct TabBarNavigationSync: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> TabBarNavigationSyncController {
        TabBarNavigationSyncController()
    }

    func updateUIViewController(_ controller: TabBarNavigationSyncController, context: Context) {
        controller.installIfNeeded()
    }
}

private final class TabBarNavigationSyncController: UIViewController, UINavigationControllerDelegate {
    private weak var observedNavigationController: UINavigationController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installIfNeeded()
    }

    func installIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let navigationController = self.navigationController,
                  self.observedNavigationController !== navigationController else {
                return
            }
            self.observedNavigationController = navigationController
            navigationController.delegate = self
        }
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        let isShowingRoot = navigationController.viewControllers.first === viewController
        TabBarAppearance.setHidden(!isShowingRoot, for: navigationController, animated: animated)
    }
}

private final class TabBarVisibilityController: UIViewController {
    private var lastHiddenState: Bool?
    private var pendingHiddenState = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lastHiddenState = nil
        applyTabBarHidden(pendingHiddenState, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if pendingHiddenState {
            applyTabBarHidden(false, animated: animated)
        }
    }

    func setTabBarHidden(_ hidden: Bool, animated: Bool) {
        pendingHiddenState = hidden
        applyTabBarHidden(hidden, animated: animated)
    }

    private func applyTabBarHidden(_ hidden: Bool, animated: Bool) {
        var effectiveHidden = hidden
        if !hidden,
           let navigationController,
           navigationController.viewControllers.count > 1 {
            effectiveHidden = true
        }
        guard lastHiddenState != effectiveHidden else { return }
        lastHiddenState = effectiveHidden

        TabBarAppearance.setHidden(effectiveHidden, for: self, animated: animated)
    }
}

private enum TabBarAppearance {
    static func setHidden(_ hidden: Bool, for controller: UIViewController, animated: Bool) {
        DispatchQueue.main.async {
            guard let tabBar = controller.tabBarController?.tabBar else { return }
            let duration = animated ? 0.18 : 0
            tabBar.transform = .identity

            if hidden {
                tabBar.isHidden = false
                tabBar.isUserInteractionEnabled = false
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    tabBar.alpha = 0
                } completion: { finished in
                    if finished && tabBar.alpha == 0 {
                        tabBar.isHidden = true
                        tabBar.transform = .identity
                    }
                }
            } else {
                tabBar.isHidden = false
                tabBar.isUserInteractionEnabled = true
                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState]
                ) {
                    tabBar.alpha = 1
                }
            }
        }
    }
}

private struct CleanerHeader: View {
    let title: String

    var body: some View {
        Color.clear
            .frame(height: 0)
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .background(.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.cleanerBorder)
                    .frame(height: 0.5)
            }
    }
}

private struct StorageCard: View {
    let label: String
    let value: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    storageLabel
                    Spacer(minLength: 12)
                    storageValue
                }
                VStack(alignment: .leading, spacing: 4) {
                    storageLabel
                    storageValue
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.cleanerCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .background(.white)
    }

    private var storageLabel: some View {
        Text(label.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }

    private var storageValue: some View {
        Text(value)
            .font(.title.bold())
            .foregroundStyle(Color.cleanerBlue)
            .minimumScaleFactor(0.75)
    }
}

private struct CleanerSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.cleanerBackground)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
            VStack(spacing: 0) {
                content
            }
            .background(.white)
        }
    }
}

private struct CategoryRow: View {
    let item: CleanerCategory
    let loadingText: String?

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(item.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.cleanerText)
                if let loadingText {
                    Text(loadingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(String.localizedStringWithFormat(String(localized: "items.count.format"), item.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if loadingText != nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else if !item.size.isEmpty {
                Text(item.size)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.cleanerText)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.trailing, 20)
        .frame(minHeight: 56)
        .background(.white)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 20) }
    }
}

private struct CleanerToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.82), in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

private struct SimilarGroup: View {
    let title: String
    let mode: PhotoGroupCleanMode
    let group: SimilarAssetGroup
    @Binding var selectedIDs: Set<String>
    @Binding var previewPhoto: IdentifiablePHAsset?
    @EnvironmentObject private var library: PhotoLibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Button(allCandidatesSelected ? "select.none" : "select.all") {
                    if allCandidatesSelected {
                        selectedIDs.subtract(candidateIDs)
                    } else {
                        selectedIDs.formUnion(candidateIDs)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cleanerBlue)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(group.assets) { photo in
                        SimilarPhotoCard(
                            photo: photo,
                            selected: selectedIDs.contains(photo.id),
                            storageText: formattedStorage(library.storageBytes(for: photo.asset)),
                            insight: insight(for: photo)
                        ) {
                            previewPhoto = IdentifiablePHAsset(asset: photo.asset)
                        } toggle: {
                            if selectedIDs.contains(photo.id) {
                                selectedIDs.remove(photo.id)
                            } else {
                                selectedIDs.insert(photo.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var candidateIDs: Set<String> {
        Set(group.assets.filter { !$0.isBest }.map(\.id))
    }

    private var allCandidatesSelected: Bool {
        !candidateIDs.isEmpty && candidateIDs.isSubset(of: selectedIDs)
    }

    private func insight(for photo: SimilarAsset) -> BurstPhotoInsight? {
        guard mode == .burst else { return nil }
        let bestScore = group.assets.map(\.qualityScore).max() ?? photo.qualityScore
        let scoreGap = bestScore - photo.qualityScore
        let megapixels = Double(photo.asset.pixelWidth * photo.asset.pixelHeight) / 1_000_000

        if photo.isBest {
            if photo.asset.isFavorite {
                return BurstPhotoInsight(text: String(localized: "ai.tag.favorite.keep"), tint: .yellow)
            }
            return BurstPhotoInsight(text: String(localized: "ai.tag.best.keep"), tint: .cleanerGreen)
        }
        if scoreGap > 0.18 {
            return BurstPhotoInsight(text: String(localized: "ai.tag.lower.quality"), tint: .orange)
        }
        if photo.qualityScore < 0.34 {
            return BurstPhotoInsight(text: String(localized: "ai.tag.possible.blur"), tint: .orange)
        }
        if megapixels >= 12 {
            return BurstPhotoInsight(text: String(localized: "ai.tag.high.resolution"), tint: .cleanerBlue)
        }
        return BurstPhotoInsight(text: String(localized: "ai.tag.similar.cleanable"), tint: .secondary)
    }
}

private struct BurstPhotoInsight {
    let text: String
    let tint: Color
}

private struct SimilarPhotoCard: View {
    let photo: SimilarAsset
    let selected: Bool
    let storageText: String
    let insight: BurstPhotoInsight?
    let preview: () -> Void
    let toggle: () -> Void

    var body: some View {
        let cardWidth: CGFloat = photo.asset.pixelWidth > photo.asset.pixelHeight ? 142 : 108
        let cardHeight: CGFloat = insight == nil ? 146 : 178

        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                PhotoThumbnailView(
                    asset: photo.asset,
                    targetSize: CGSize(width: 132, height: 146)
                )
                .assetPreviewSource(id: photo.id)
                .frame(width: cardWidth, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .frame(width: cardWidth, height: 146, alignment: .top)

            if photo.isBest {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            Button(action: toggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        selected ? .white : .white.opacity(0.9),
                        selected ? Color.cleanerBlue : Color.black.opacity(0.25)
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .padding(.trailing, 2)

            HStack {
                Text(storageText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.52), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: cardWidth, height: 146, alignment: .bottomLeading)

            if let insight {
                Text(insight.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(insight.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 7)
                    .frame(width: cardWidth, height: 24, alignment: .leading)
                    .background(insight.tint.opacity(0.12), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }
}

private struct BottomActionBar: View {
    let text: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                actionSummary
                Spacer(minLength: 12)
                actionButton
            }

            VStack(alignment: .leading, spacing: 10) {
                actionSummary
                actionButton
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
    }

    private var actionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text)
                .font(.subheadline.weight(.bold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButton: some View {
        Button(buttonTitle, action: action)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ActionCircle: View {
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .background(Color.cleanerCard, in: Circle())
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                content
                    .toggleStyle(SwitchToggleStyle(tint: .cleanerGreen))
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
        }
        .padding(.horizontal, 16)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let value: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.cleanerBlue)
                .frame(width: 24)
            Text(title)
                .layoutPriority(1)
            Spacer()
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 52) }
    }
}

private struct InfoPair: View {
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                titleText
                Spacer(minLength: 12)
                valueText
            }
            VStack(alignment: .leading, spacing: 4) {
                titleText
                valueText
            }
        }
        .font(.subheadline)
    }

    private var titleText: some View {
        Text(title)
            .foregroundStyle(.secondary)
    }

    private var valueText: some View {
        Text(value)
            .fontWeight(.semibold)
            .multilineTextAlignment(.trailing)
    }
}

struct CleanerCategory: Identifiable {
    enum Kind: Hashable {
        case duplicate, burst, screenshot, livePhoto, lowQuality, video, largeVideo, recording, emptyAlbum

        var usesAssetGrid: Bool {
            switch self {
            case .screenshot, .video, .largeVideo, .recording:
                return true
            case .duplicate, .burst, .livePhoto, .lowQuality, .emptyAlbum:
                return false
            }
        }
    }

    var id: Kind { kind }
    let title: String
    let count: Int
    let size: String
    let color: Color
    let icon: String
    let kind: Kind

    func with(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: title,
            count: count,
            size: size,
            color: color,
            icon: icon,
            kind: kind
        )
    }

    static func duplicates(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.duplicates"),
            count: count,
            size: size,
            color: .orange,
            icon: "rectangle.on.rectangle",
            kind: .duplicate
        )
    }

    static func bursts(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.bursts"),
            count: count,
            size: size,
            color: .cleanerGreen,
            icon: "camera.on.rectangle",
            kind: .burst
        )
    }

    static func screenshots(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.screenshots"),
            count: count,
            size: size,
            color: .red,
            icon: "iphone",
            kind: .screenshot
        )
    }

    static func livePhotos(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.live.photos"),
            count: count,
            size: size,
            color: .cleanerBlue,
            icon: "livephoto",
            kind: .livePhoto
        )
    }

    static func allVideos(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.all.videos"),
            count: count,
            size: size,
            color: .cyan,
            icon: "video",
            kind: .video
        )
    }

    static func largeVideos(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.large.videos"),
            count: count,
            size: size,
            color: .orange,
            icon: "video.fill",
            kind: .largeVideo
        )
    }

    static func screenRecordings(count: Int, size: String = "") -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.screen.recordings"),
            count: count,
            size: size,
            color: .gray,
            icon: "record.circle",
            kind: .recording
        )
    }

    static func emptyAlbums(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.empty.albums"),
            count: count,
            size: "",
            color: Color(red: 0.733, green: 0.420, blue: 0.851),
            icon: "folder",
            kind: .emptyAlbum
        )
    }
}

private extension Color {
    static let cleanerBlue = Color(red: 0.035, green: 0.412, blue: 0.855)
    static let cleanerGreen = Color(red: 0.102, green: 0.498, blue: 0.216)
    static let cleanerBackground = Color(red: 0.965, green: 0.973, blue: 0.98)
    static let cleanerCard = Color(red: 0.965, green: 0.973, blue: 0.98)
    static let cleanerBorder = Color(red: 0.882, green: 0.894, blue: 0.91)
    static let cleanerText = Color(red: 0.122, green: 0.137, blue: 0.157)
}
