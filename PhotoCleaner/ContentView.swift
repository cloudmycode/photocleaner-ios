import AVKit
import Photos
import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .clean

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                QuickCleanView()
            }
            .tabItem { Label(String(localized: "tab.quick"), systemImage: "sparkles.rectangle.stack") }
            .tag(AppTab.clean)

            NavigationStack {
                AlbumsView()
            }
            .tabItem { Label(String(localized: "tab.albums"), systemImage: "photo.on.rectangle") }
            .tag(AppTab.albums)

            NavigationStack {
                VideoCompressView()
            }
            .tabItem { Label(String(localized: "tab.compress"), systemImage: "video.badge.waveform") }
            .tag(AppTab.compress)

            NavigationStack {
                SettingsView()
            }
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

struct QuickCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService

    private var photoItems: [CleanerCategory] {
        [
            CleanerCategory.duplicates(
                count: library.duplicateGroups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
            ),
            CleanerCategory.bursts(
                count: library.burstGroups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
            ),
            CleanerCategory.similar(
                count: library.similarGroups.reduce(0) { $0 + max($1.assets.count - 1, 0) }
            ),
            CleanerCategory.screenshots(count: library.screenshotAssets.count)
        ]
    }

    private var videoItems: [CleanerCategory] {
        [
            CleanerCategory.allVideos(count: library.videoAssets.count),
            CleanerCategory.largeVideos(count: library.largeVideoAssets.count),
            CleanerCategory.screenRecordings(count: library.screenRecordingAssets.count)
        ]
    }

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "app.name"))
            if hasPhotoAccess {
                StorageCard(
                    label: String(localized: "library.media"),
                    value: "\(library.photoCount + library.videoCount)",
                    description: String.localizedStringWithFormat(
                        String(localized: "library.summary.format"),
                        library.photoCount,
                        library.videoCount
                    )
                )

                CleanerSection(title: String(localized: "section.photos")) {
                    ForEach(photoItems) { item in
                        NavigationLink {
                            if item.kind == .duplicate {
                                SimilarCleanView(mode: .duplicate)
                            } else if item.kind == .burst {
                                SimilarCleanView(mode: .burst)
                            } else if item.kind == .similar {
                                SimilarCleanView(mode: .similar)
                            } else {
                                AssetSwipeCleanView(category: item)
                            }
                        } label: {
                            CategoryRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }

                CleanerSection(title: String(localized: "section.videos")) {
                    ForEach(videoItems) { item in
                        NavigationLink {
                            AssetSwipeCleanView(category: item)
                        } label: {
                            CategoryRow(item: item)
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
    }

    private var scanStatus: String {
        switch library.authorizationStatus {
        case .denied, .restricted:
            return String(localized: "photo.access.required")
        case .notDetermined:
            return String(localized: "photo.access.requesting")
        default:
            if case let .analyzing(current, total) = library.scanState {
                return String.localizedStringWithFormat(
                    String(localized: "similar.analyzing.format"),
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
    @State private var photoOffset: CGSize = .zero
    @State private var settledPhotoOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var isMagnifying = false
    @State private var showDeleteConfirmation = false
    @State private var deletionError: String?

    private var availableAssets: [PHAsset] {
        assets.filter { !removedIDs.contains($0.localIdentifier) }
    }

    private var currentAsset: PHAsset? {
        availableAssets.first { !reviewedIDs.contains($0.localIdentifier) }
    }

    private var reviewedCount: Int {
        reviewedIDs.intersection(Set(availableAssets.map(\.localIdentifier))).count
    }

    var body: some View {
        Group {
            if let asset = currentAsset {
                ScrollView {
                    VStack(spacing: 18) {
                        reviewToolbar
                        reviewCard(asset)
                        HStack(spacing: 36) {
                            ActionCircle(systemName: "trash", tint: .red) {
                                review(asset, markForDeletion: true)
                            }
                            .accessibilityLabel(Text("mark.for.deletion"))

                            ActionCircle(systemName: "checkmark", tint: .cleanerGreen) {
                                review(asset, markForDeletion: false)
                            }
                            .accessibilityLabel(Text("keep"))
                        }
                        Color.clear.frame(height: 12)
                    }
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
            reviewedIDs = library.reviewedIDs(for: monthID)
            markedIDs = library.markedIDs(for: monthID)
        }
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

    private func reviewCard(_ asset: PHAsset) -> some View {
        ZStack(alignment: .topLeading) {
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 880, height: 1100)
            )
            .id(asset.localIdentifier)
            .scaleEffect(scale)
            .offset(photoOffset)

            if scale > 1.01 {
                Button {
                    resetPhotoTransform()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(12)
                .accessibilityLabel(Text("photo.reset.zoom"))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 440)
        .aspectRatio(0.84, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            if scale <= 1.01, offset.width < -30 {
                swipeBadge(
                    title: String(localized: "mark.for.deletion"),
                    systemName: "trash",
                    color: .red,
                    alignment: .topTrailing
                )
            } else if scale <= 1.01, offset.width > 30 {
                swipeBadge(
                    title: String(localized: "keep"),
                    systemName: "checkmark",
                    color: .cleanerGreen,
                    alignment: .topLeading
                )
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        .offset(offset)
        .rotationEffect(.degrees(Double(offset.width / 18)))
        .simultaneousGesture(monthlyMagnifyGesture)
        .simultaneousGesture(monthlyDragGesture(for: asset))
        .padding(.horizontal, 22)
    }

    private var monthlyMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isMagnifying = true
                scale = min(max(settledScale * value.magnification, 0.75), 4)
                offset = .zero
                if scale <= 1 {
                    photoOffset = .zero
                }
            }
            .onEnded { _ in
                isMagnifying = false
                if scale <= 1 {
                    resetPhotoTransform()
                } else {
                    settledScale = scale
                }
            }
    }

    private func monthlyDragGesture(for asset: PHAsset) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isMagnifying else { return }
                if scale > 1 {
                    photoOffset = CGSize(
                        width: settledPhotoOffset.width + value.translation.width,
                        height: settledPhotoOffset.height + value.translation.height
                    )
                } else {
                    offset = value.translation
                }
            }
            .onEnded { value in
                guard !isMagnifying else {
                    offset = .zero
                    return
                }
                if scale > 1 {
                    settledPhotoOffset = photoOffset
                } else {
                    if value.translation.width < -110 {
                        review(asset, markForDeletion: true)
                    } else if value.translation.width > 110 {
                        review(asset, markForDeletion: false)
                    }
                    offset = .zero
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
        resetPhotoTransform()
    }

    private func undo() {
        guard let action = history.popLast() else { return }
        reviewedIDs.remove(action.id)
        library.setMonthlyAsset(action.id, reviewed: false, monthID: monthID)
        if action.markedForDeletion {
            markedIDs.remove(action.id)
        }
        resetPhotoTransform()
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

    private func resetPhotoTransform() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            settledScale = 1
            isMagnifying = false
            offset = .zero
            photoOffset = .zero
            settledPhotoOffset = .zero
        }
    }
}

private struct MonthAssetRow: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let group: PhotoMonthGroup

    private var progress: Double {
        library.monthlyProgress(for: group)
    }

    private var reviewedCount: Int {
        let availableIDs = Set(group.assets.map(\.localIdentifier))
        return library.reviewedIDs(for: group.id)
            .intersection(availableIDs)
            .count
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
    case similar
}

struct SimilarCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    let mode: PhotoGroupCleanMode
    @State private var selectedIDs = Set<String>()
    @State private var previewPhoto: SimilarAsset?
    @State private var deletionError: String?
    @State private var showDeleteConfirmation = false

    private var selectedCount: Int { selectedIDs.count }
    private var groups: [SimilarAssetGroup] {
        switch mode {
        case .duplicate:
            return library.duplicateGroups
        case .burst:
            return library.burstGroups
        case .similar:
            return library.similarGroups
        }
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
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedCount > 0 {
                BottomActionBar(
                    text: String.localizedStringWithFormat(String(localized: "selected.photos.format"), selectedCount),
                    detail: "",
                    buttonTitle: String(localized: "move.to.trash")
                ) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewPhoto) { photo in
            PhotoPreview(photo: photo, isSelected: selectedIDs.contains(photo.id)) {
                toggle(photo)
            }
            .presentationDetents([.fraction(0.9), .large])
            .presentationDragIndicator(.visible)
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
        }
        .onAppear {
            selectNonBestPhotos()
        }
        .background(Color.cleanerBackground)
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
                if library.scanState == .finished {
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
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    SimilarGroup(
                        title: groupTitle(group, index: index),
                        group: group,
                        selectedIDs: $selectedIDs,
                        previewPhoto: $previewPhoto
                    )
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
        if mode == .burst {
            return String(localized: "burst.reading")
        }
        if case let .analyzing(current, total) = library.scanState {
            return String.localizedStringWithFormat(
                String(localized: "similar.analyzing.format"),
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

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.title"
        case .burst:
            return "burst.title"
        case .similar:
            return "similar.title"
        }
    }

    private var keptKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.original.kept"
        case .burst:
            return "burst.best.pick"
        case .similar:
            return "similar.best.pick"
        }
    }

    private var emptyTitleKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.empty"
        case .burst:
            return "burst.empty"
        case .similar:
            return "similar.empty"
        }
    }

    private var emptyDescriptionKey: LocalizedStringKey {
        switch mode {
        case .duplicate:
            return "duplicate.empty.description"
        case .burst:
            return "burst.empty.description"
        case .similar:
            return "similar.empty.description"
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

    private var assets: [PHAsset] {
        sourceAssets.filter { !excludedIDs.contains($0.localIdentifier) }
    }

    private var currentAsset: PHAsset? {
        assets.first
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
        .background(Color.cleanerBackground)
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
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: 440)
                    .aspectRatio(0.84, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            } else {
                PhotoThumbnailView(
                    asset: asset,
                    targetSize: CGSize(width: 880, height: 1100)
                )
                .id(asset.localIdentifier)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: 440)
                .aspectRatio(0.84, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .offset(offset)
                .rotationEffect(.degrees(Double(offset.width / 18)))
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

    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            if let player {
                VideoPlayer(player: player)
                    .scaleEffect(scale)
                    .offset(offset)
                    .simultaneousGesture(magnifyGesture)
                    .simultaneousGesture(panGesture)
            } else {
                ProgressView()
                    .tint(.white)
            }

            if scale > 1.01 {
                Button {
                    resetTransform()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(12)
                .accessibilityLabel(Text("video.reset.zoom"))
            }
        }
        .clipped()
        .onAppear {
            requestPlayer()
        }
        .onDisappear {
            player?.pause()
            if let requestID {
                library.cancelImageRequest(requestID)
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 4)
                if scale <= 1.01 {
                    offset = .zero
                }
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 {
                    settledOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                settledOffset = offset
            }
    }

    private func requestPlayer() {
        requestID = library.requestPlayerItem(for: asset) { item in
            guard let item else { return }
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
        }
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
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
                        AssetSwipeCleanView(category: category)
                    } label: {
                        CategoryRow(item: category)
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
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var showCacheConfirmation = false

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

private struct CleanerHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(Color.cleanerText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .background(.white)
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

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(item.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.cleanerText)
                Text(String.localizedStringWithFormat(String(localized: "items.count.format"), item.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !item.size.isEmpty {
                Text(item.size)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.cleanerText)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
        .background(.white)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 20) }
    }
}

private struct SimilarGroup: View {
    let title: String
    let group: SimilarAssetGroup
    @Binding var selectedIDs: Set<String>
    @Binding var previewPhoto: SimilarAsset?

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
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group.assets) { photo in
                        SimilarPhotoCard(photo: photo, selected: selectedIDs.contains(photo.id)) {
                            previewPhoto = photo
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
}

private struct SimilarPhotoCard: View {
    let photo: SimilarAsset
    let selected: Bool
    let preview: () -> Void
    let toggle: () -> Void

    var body: some View {
        let cardWidth: CGFloat = photo.asset.pixelWidth > photo.asset.pixelHeight ? 142 : 108

        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                PhotoThumbnailView(
                    asset: photo.asset,
                    targetSize: CGSize(width: 132, height: 146)
                )
                .frame(width: cardWidth, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

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
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .padding(.trailing, 2)
        }
        .frame(width: cardWidth, height: 146)
    }
}

private struct PhotoPreview: View {
    let photo: SimilarAsset
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PhotoThumbnailView(
                    asset: photo.asset,
                    targetSize: CGSize(width: 720, height: 540)
                )
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                VStack(spacing: 12) {
                    InfoPair(
                        title: String(localized: "photo.time"),
                        value: photo.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "-"
                    )
                    InfoPair(
                        title: String(localized: "photo.location"),
                        value: photo.asset.location == nil ? "-" : String(localized: "location.available")
                    )
                    InfoPair(
                        title: String(localized: "photo.model"),
                        value: "\(photo.asset.pixelWidth) x \(photo.asset.pixelHeight)"
                    )
                    InfoPair(
                        title: String(localized: "photo.size"),
                        value: photo.isBest ? String(localized: "similar.best.pick") : "-"
                    )
                }
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
                .padding(.horizontal, 20)

                Button(isSelected ? String(localized: "unselect") : String(localized: "select")) {
                    toggle()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background(Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color.cleanerBackground)
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
        case duplicate, burst, similar, screenshot, lowQuality, video, largeVideo, recording, emptyAlbum
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

    static func similar(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.similar"),
            count: count,
            size: "",
            color: .cleanerBlue,
            icon: "photo.stack",
            kind: .similar
        )
    }

    static func duplicates(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.duplicates"),
            count: count,
            size: "",
            color: .orange,
            icon: "rectangle.on.rectangle",
            kind: .duplicate
        )
    }

    static func bursts(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.bursts"),
            count: count,
            size: "",
            color: .cleanerGreen,
            icon: "camera.on.rectangle",
            kind: .burst
        )
    }

    static func screenshots(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.screenshots"),
            count: count,
            size: "",
            color: .red,
            icon: "iphone",
            kind: .screenshot
        )
    }

    static func allVideos(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.all.videos"),
            count: count,
            size: "",
            color: .cyan,
            icon: "video",
            kind: .video
        )
    }

    static func largeVideos(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.large.videos"),
            count: count,
            size: "",
            color: .orange,
            icon: "video.fill",
            kind: .largeVideo
        )
    }

    static func screenRecordings(count: Int) -> CleanerCategory {
        CleanerCategory(
            title: String(localized: "category.screen.recordings"),
            count: count,
            size: "",
            color: .gray,
            icon: "record.circle",
            kind: .recording
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
