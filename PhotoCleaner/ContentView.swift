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

    private let videoItems = CleanerCategory.videoSamples
    private let albumItems = CleanerCategory.albumSamples

    private var photoItems: [CleanerCategory] {
        CleanerCategory.photoSamples.map { item in
            switch item.kind {
            case .similar:
                return item.with(count: library.similarGroups.reduce(0) { $0 + $1.assets.count })
            case .screenshot:
                return item.with(count: library.screenshotCount)
            case .largeImage:
                return item.with(count: library.largeImageAssets.count)
            default:
                return item
            }
        }
    }

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "app.name"))
            StorageCard(label: String(localized: "media.storage"), value: "42.15 GB", description: String(localized: "media.storage.description"))

            CleanerSection(title: String(localized: "section.photos")) {
                ForEach(photoItems) { item in
                    NavigationLink {
                        if item.kind == .similar {
                            SimilarCleanView()
                        } else if item.kind == .screenshot {
                            AssetSwipeCleanView(category: item)
                        } else if item.kind == .largeImage {
                            AssetSwipeCleanView(category: item)
                        } else {
                            SwipeCleanView(category: item)
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
                        SwipeCleanView(category: item)
                    } label: {
                        CategoryRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }

            CleanerSection(title: String(localized: "section.albums")) {
                ForEach(albumItems) { item in
                    CategoryRow(item: item)
                }
            }

            Text("analysis.complete")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
        .background(Color.cleanerBackground)
    }
}

struct AlbumsView: View {
    private let months = AlbumMonth.samples

    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "tab.albums"))
            StorageCard(label: String(localized: "total.photos"), value: String(localized: "total.photos.value"), description: String(localized: "total.photos.description"))

            CleanerSection(title: "2026") {
                ForEach(months) { month in
                    AlbumRow(month: month)
                }
            }

            Text("albums.footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
        }
        .background(Color.cleanerBackground)
    }
}

struct SimilarCleanView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var selectedIDs = Set<String>()
    @State private var previewPhoto: SimilarAsset?
    @State private var deletionError: String?

    private var selectedCount: Int { selectedIDs.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("similar.title")
                            .font(.title2.bold())
                        Spacer()
                        Text("similar.best.pick")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.cleanerGreen.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.cleanerGreen)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("similar.title")
                            .font(.title2.bold())
                        Text("similar.best.pick")
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
                    deleteSelected()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewPhoto) { photo in
            PhotoPreview(photo: photo, isSelected: selectedIDs.contains(photo.id)) {
                toggle(photo)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("delete.failed", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .onChange(of: library.similarGroups.map(\.id)) {
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
            if library.similarGroups.isEmpty {
                if library.scanState == .finished {
                    ContentUnavailableView(
                        "similar.empty",
                        systemImage: "checkmark.circle",
                        description: Text("similar.empty.description")
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
                ForEach(Array(library.similarGroups.enumerated()), id: \.element.id) { index, group in
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
        guard let date = group.creationDate else { return "Group \(index + 1)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func selectNonBestPhotos() {
        let available = Set(library.similarGroups.flatMap(\.assets).map(\.id))
        selectedIDs.formIntersection(available)
        if selectedIDs.isEmpty {
            selectedIDs = Set(
                library.similarGroups
                    .flatMap(\.assets)
                    .filter { !$0.isBest }
                    .map(\.id)
            )
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

    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var showInfo = false
    @State private var excludedIDs = Set<String>()
    @State private var history: [String] = []
    @State private var favoriteOverrides: [String: Bool] = [:]
    @State private var operationError: String?

    private var sourceAssets: [PHAsset] {
        switch category.kind {
        case .screenshot:
            return library.screenshotAssets
        case .largeImage:
            return library.largeImageAssets
        default:
            return []
        }
    }

    private var assets: [PHAsset] {
        sourceAssets.filter { !excludedIDs.contains($0.localIdentifier) }
    }

    private var currentAsset: PHAsset? {
        guard assets.indices.contains(index) else { return nil }
        return assets[index]
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
                    actionBar(asset)
                }
            } else {
                ContentUnavailableView(
                    "cleanup.complete",
                    systemImage: "checkmark.circle",
                    description: Text("cleanup.complete.description")
                )
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
        .onChange(of: assets.map(\.localIdentifier)) {
            index = min(index, max(assets.count - 1, 0))
        }
    }

    private var toolbar: some View {
        HStack {
            Text("\(min(index + 1, assets.count))/\(assets.count)")
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
            PhotoThumbnailView(
                asset: asset,
                targetSize: CGSize(width: 880, height: 1100)
            )
            .id(asset.localIdentifier)
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
                            delete(asset)
                        } else if value.translation.width > 110 {
                            keep(asset)
                        }
                        offset = .zero
                    }
            )

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
                delete(asset)
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

    private func keep(_ asset: PHAsset) {
        history.append(asset.localIdentifier)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            if index < assets.count - 1 {
                index += 1
            } else {
                excludedIDs.insert(asset.localIdentifier)
                index = min(index, max(assets.count - 1, 0))
            }
        }
    }

    private func delete(_ asset: PHAsset) {
        let id = asset.localIdentifier
        Task {
            do {
                try await library.deleteAssets(with: Set([id]))
                excludedIDs.insert(id)
                index = min(index, max(assets.count - 1, 0))
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func undo() {
        guard let id = history.popLast() else { return }
        if excludedIDs.remove(id) != nil,
           let restoredIndex = assets.firstIndex(where: { $0.localIdentifier == id }) {
            index = restoredIndex
        } else {
            index = max(0, index - 1)
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

struct SwipeCleanView: View {
    let category: CleanerCategory
    @State private var index = 0
    @State private var offset: CGSize = .zero
    @State private var showInfo = false

    private let cards = SwipePhoto.samples

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("\(index + 1)/\(cards.count)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("undo") {
                        index = max(0, index - 1)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(cards[index].gradient)
                        .overlay {
                            VStack(spacing: 14) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 46, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text(cards[index].title)
                                    .font(.title2.weight(.bold))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                                Text(cards[index].subtitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            .padding(24)
                        }
                        .frame(maxWidth: 440)
                        .aspectRatio(0.84, contentMode: .fit)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                        .offset(offset)
                        .rotationEffect(.degrees(Double(offset.width / 18)))
                        .gesture(
                            DragGesture()
                                .onChanged { offset = $0.translation }
                                .onEnded { value in
                                    if abs(value.translation.width) > 110 {
                                        advance()
                                    }
                                    offset = .zero
                                }
                        )

                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(18)
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                if showInfo {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("2026-06-05 14:22", systemImage: "calendar")
                        Label("Beijing Haidian", systemImage: "location")
                        Label("4.8 MB (4032 x 3024)", systemImage: "internaldrive")
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
                Color.clear.frame(height: 20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            swipeActions
            .padding(20)
            .background(.white)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color.cleanerBackground)
    }

    private func advance() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            index = (index + 1) % cards.count
        }
    }

    private var swipeActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                actionIcons
                keepButton
            }

            VStack(spacing: 12) {
                HStack {
                    actionIcons
                }
                keepButton
            }
        }
    }

    private var actionIcons: some View {
        Group {
            ActionCircle(systemName: "trash", tint: .red) { advance() }
            ActionCircle(systemName: "square.and.arrow.up", tint: .cleanerBlue) {}
            ActionCircle(systemName: "heart", tint: .pink) {}
            ActionCircle(systemName: "square.grid.2x2", tint: .gray) {}
        }
    }

    private var keepButton: some View {
        Button("keep") { advance() }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct VideoCompressView: View {
    var body: some View {
        CleanerScroll {
            CleanerHeader(title: String(localized: "tab.compress"))
            StorageCard(label: String(localized: "media.storage"), value: "29.92 GB", description: String(localized: "compress.summary.description"))

            CleanerSection(title: String(localized: "section.videos")) {
                ForEach(VideoBucket.samples) { bucket in
                    NavigationLink {
                        CompressDetailView(bucket: bucket)
                    } label: {
                        VideoBucketRow(bucket: bucket)
                    }
                    .buttonStyle(.plain)
                }
            }

            CleanerSection(title: String(localized: "batch.compress")) {
                VideoBucketRow(bucket: VideoBucket(title: String(localized: "compress.recommended"), count: "57", size: "11.06 GB", color: .cleanerGreen, icon: "wand.and.stars"))
            }

            Text("compress.footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 28)
        }
        .background(Color.cleanerBackground)
    }
}

struct CompressDetailView: View {
    let bucket: VideoBucket
    @State private var quality: Double = 0.68

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [.black.opacity(0.9), bucket.color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                VStack(spacing: 14) {
                    HStack {
                        Text("compress.quality")
                        Spacer()
                        Text("\(Int(quality * 100))%")
                            .foregroundStyle(Color.cleanerBlue)
                            .fontWeight(.bold)
                    }
                    Slider(value: $quality, in: 0.35...0.9)
                    InfoPair(title: String(localized: "original.size"), value: bucket.size)
                    InfoPair(title: String(localized: "estimated.size"), value: "4.72 GB")
                    InfoPair(title: String(localized: "space.saved"), value: "6.34 GB")
                }
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NavigationLink {
                CompressResultView()
            } label: {
                Text("start.compress")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.cleanerBlue, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
            .background(.white)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle(bucket.title)
        .background(Color.cleanerBackground)
    }
}

struct CompressResultView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 74))
                .foregroundStyle(Color.cleanerGreen)
            Text("compress.complete")
                .font(.title.bold())
            Text("compress.complete.description")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 12) {
                InfoPair(title: String(localized: "original.size"), value: "11.06 GB")
                InfoPair(title: String(localized: "compressed.size"), value: "4.72 GB")
                InfoPair(title: String(localized: "space.saved"), value: "6.34 GB")
            }
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cleanerBorder))
            .padding(20)
            Spacer()
        }
        .background(Color.cleanerBackground)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: PhotoLibraryService
    @State private var scanSimilar = true
    @State private var diskWarning = false
    @State private var keepOriginal = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CleanerHeader(title: String(localized: "tab.settings"))

                SettingsGroup(title: String(localized: "settings.cleaning")) {
                    Toggle("settings.scan.similar", isOn: $scanSimilar)
                    SettingsNavRow(title: String(localized: "settings.whitelist"), value: String(localized: "settings.whitelist.value"))
                    Toggle("settings.disk.warning", isOn: $diskWarning)
                }

                SettingsGroup(title: String(localized: "settings.video.standard")) {
                    SettingsNavRow(title: String(localized: "settings.default.quality"), value: String(localized: "settings.quality.value"))
                    Toggle("settings.keep.original", isOn: $keepOriginal)
                }

                SettingsGroup(title: String(localized: "settings.general.security")) {
                    Button {
                        library.clearAnalysisCache()
                    } label: {
                        SettingsNavRow(
                            title: String(localized: "settings.clear.cache"),
                            value: formattedCacheSize
                        )
                    }
                    .buttonStyle(.plain)
                }

                SettingsGroup(title: String(localized: "settings.support")) {
                    SettingsNavRow(title: String(localized: "settings.email"), value: "support@smartcleaner.com")
                    SettingsNavRow(title: String(localized: "settings.rate"), value: nil)
                    SettingsNavRow(title: String(localized: "settings.share"), value: nil)
                    SettingsNavRow(title: String(localized: "settings.privacy"), value: nil)
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
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(
            fromByteCount: library.analysisCacheSize,
            countStyle: .file
        )
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
            Text(item.size)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.cleanerText)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 56)
        .background(.white)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
    }
}

private struct AlbumRow: View {
    let month: AlbumMonth

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(month.organized ? Color.cleanerGreen : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(month.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(month.organized ? .secondary : Color.cleanerText)
                Text(month.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !month.organized {
                    ProgressView(value: month.progress)
                        .tint(.cleanerBlue)
                        .frame(width: 130)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(month.size)
                    .font(.subheadline.weight(.semibold))
                if month.organized {
                    Label("organized", systemImage: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.cleanerGreen)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 72)
        .background(.white)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
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
                Button("select.all") {
                    group.assets
                        .filter { !$0.isBest }
                        .forEach { selectedIDs.insert($0.id) }
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
}

private struct SimilarPhotoCard: View {
    let photo: SimilarAsset
    let selected: Bool
    let preview: () -> Void
    let toggle: () -> Void

    var body: some View {
        Button(action: preview) {
            ZStack(alignment: .topTrailing) {
                PhotoThumbnailView(
                    asset: photo.asset,
                    targetSize: CGSize(width: 132, height: 146)
                )
                if photo.isBest {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                Button(action: toggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? .white : .white.opacity(0.8), selected ? Color.cleanerBlue : .clear)
                }
                .padding(8)
            }
            .frame(width: photo.asset.pixelWidth > photo.asset.pixelHeight ? 142 : 108, height: 146)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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

private struct VideoBucketRow: View {
    let bucket: VideoBucket

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(bucket.color)
                .frame(width: 4)
            Image(systemName: bucket.icon)
                .font(.title3)
                .foregroundStyle(bucket.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(bucket.title)
                    .font(.subheadline.weight(.semibold))
                Text(String.localizedStringWithFormat(String(localized: "videos.count.format"), bucket.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(bucket.size)
                .font(.subheadline.weight(.semibold))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 60)
        .background(.white)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
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

private struct SettingsNavRow: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .layoutPriority(1)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 16) }
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
    enum Kind {
        case duplicate, similar, screenshot, lowQuality, largeImage, video, largeVideo, recording, emptyAlbum
    }

    let id = UUID()
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

    static let photoSamples = [
        CleanerCategory(title: String(localized: "category.duplicates"), count: 124, size: "1.21 GB", color: .orange, icon: "rectangle.on.rectangle", kind: .duplicate),
        CleanerCategory(title: String(localized: "category.similar"), count: 1957, size: "5.31 GB", color: .cleanerBlue, icon: "photo.stack", kind: .similar),
        CleanerCategory(title: String(localized: "category.screenshots"), count: 412, size: "50.8 MB", color: .red, icon: "iphone", kind: .screenshot),
        CleanerCategory(title: String(localized: "category.low.quality"), count: 6, size: "1.4 MB", color: .purple, icon: "exclamationmark.triangle", kind: .lowQuality),
        CleanerCategory(title: String(localized: "category.large.images"), count: 85, size: "2.52 GB", color: .cleanerGreen, icon: "photo", kind: .largeImage)
    ]

    static let videoSamples = [
        CleanerCategory(title: String(localized: "category.all.videos"), count: 1167, size: "29.92 GB", color: .cyan, icon: "video", kind: .video),
        CleanerCategory(title: String(localized: "category.large.videos"), count: 57, size: "11.06 GB", color: .orange, icon: "video.fill", kind: .largeVideo),
        CleanerCategory(title: String(localized: "category.screen.recordings"), count: 3, size: "76.2 MB", color: .gray, icon: "record.circle", kind: .recording)
    ]

    static let albumSamples = [
        CleanerCategory(title: String(localized: "category.empty.albums"), count: 10, size: "0 KB", color: .purple, icon: "folder", kind: .emptyAlbum)
    ]
}

private struct AlbumMonth: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let size: String
    let progress: Double
    let organized: Bool

    static let samples = [
        AlbumMonth(title: String(localized: "month.june"), subtitle: String(localized: "month.june.subtitle"), size: "512.0 MB", progress: 0.05, organized: false),
        AlbumMonth(title: String(localized: "month.may"), subtitle: String(localized: "month.may.subtitle"), size: "480.5 MB", progress: 1, organized: true),
        AlbumMonth(title: String(localized: "month.april"), subtitle: String(localized: "month.april.subtitle"), size: "821.4 MB", progress: 0.35, organized: false),
        AlbumMonth(title: String(localized: "month.march"), subtitle: String(localized: "month.march.subtitle"), size: "690.2 MB", progress: 0.62, organized: false)
    ]
}

private struct SimilarPhoto: Identifiable {
    let id: String
    let title: String
    let shortTitle: String
    let time: String
    let location: String
    let model: String
    let size: String
    let best: Bool
    let selected: Bool
    let landscape: Bool
    let gradient: LinearGradient

    static let samples = [
        SimilarPhoto(id: "pic-1", title: String(localized: "photo.baby.best"), shortTitle: String(localized: "photo.portrait.one"), time: "2026-06-01 12:30", location: "Beijing", model: "iPhone 15 Pro", size: "4.2 MB", best: true, selected: false, landscape: false, gradient: .photoWarm),
        SimilarPhoto(id: "pic-2", title: String(localized: "photo.baby.blink"), shortTitle: String(localized: "photo.portrait.two"), time: "2026-06-01 12:31", location: "Beijing", model: "iPhone 15 Pro", size: "3.8 MB", best: false, selected: true, landscape: false, gradient: .photoSoft),
        SimilarPhoto(id: "pic-3", title: String(localized: "photo.sunset.best"), shortTitle: String(localized: "photo.landscape.one"), time: "2026-05-20 19:05", location: "Sanya", model: "Xiaomi 14 Ultra", size: "6.5 MB", best: true, selected: false, landscape: true, gradient: .photoSunset),
        SimilarPhoto(id: "pic-4", title: String(localized: "photo.sunset.over"), shortTitle: String(localized: "photo.landscape.two"), time: "2026-05-20 19:05", location: "Sanya", model: "Xiaomi 14 Ultra", size: "6.1 MB", best: false, selected: true, landscape: true, gradient: .photoSea),
        SimilarPhoto(id: "pic-5", title: String(localized: "photo.sunset.blur"), shortTitle: String(localized: "photo.landscape.three"), time: "2026-05-20 19:06", location: "Sanya", model: "Xiaomi 14 Ultra", size: "4.9 MB", best: false, selected: true, landscape: true, gradient: .photoBlue),
        SimilarPhoto(id: "pic-6", title: String(localized: "photo.skate.one"), shortTitle: String(localized: "photo.burst.one"), time: "2026-05-10", location: "Chengdu", model: "iPhone 15", size: "4.1 MB", best: true, selected: false, landscape: false, gradient: .photoStreet),
        SimilarPhoto(id: "pic-7", title: String(localized: "photo.skate.two"), shortTitle: String(localized: "photo.burst.two"), time: "2026-05-10", location: "Chengdu", model: "iPhone 15", size: "4.0 MB", best: false, selected: true, landscape: false, gradient: .photoNight)
    ]
}

private struct SwipePhoto {
    let title: String
    let subtitle: String
    let gradient: LinearGradient

    static let samples = [
        SwipePhoto(title: String(localized: "swipe.card.id"), subtitle: "IMG_1021.JPG", gradient: .photoWarm),
        SwipePhoto(title: String(localized: "photo.baby.blink"), subtitle: "IMG_1022.JPG", gradient: .photoSoft),
        SwipePhoto(title: String(localized: "photo.sunset.blur"), subtitle: "IMG_1023.JPG", gradient: .photoSunset),
        SwipePhoto(title: String(localized: "photo.skate.two"), subtitle: "IMG_1024.JPG", gradient: .photoStreet)
    ]
}

struct VideoBucket: Identifiable {
    let id = UUID()
    let title: String
    let count: String
    let size: String
    let color: Color
    let icon: String

    static let samples = [
        VideoBucket(title: String(localized: "category.all.videos"), count: "1,167", size: "29.92 GB", color: .cleanerBlue, icon: "video"),
        VideoBucket(title: String(localized: "category.large.videos"), count: "57", size: "11.06 GB", color: .orange, icon: "externaldrive.badge.exclamationmark"),
        VideoBucket(title: String(localized: "category.screen.recordings"), count: "3", size: "76.2 MB", color: .purple, icon: "record.circle")
    ]
}

private extension Color {
    static let cleanerBlue = Color(red: 0.035, green: 0.412, blue: 0.855)
    static let cleanerGreen = Color(red: 0.102, green: 0.498, blue: 0.216)
    static let cleanerBackground = Color(red: 0.965, green: 0.973, blue: 0.98)
    static let cleanerCard = Color(red: 0.965, green: 0.973, blue: 0.98)
    static let cleanerBorder = Color(red: 0.882, green: 0.894, blue: 0.91)
    static let cleanerText = Color(red: 0.122, green: 0.137, blue: 0.157)
}

private extension LinearGradient {
    static let photoWarm = LinearGradient(colors: [.orange, .brown], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoSoft = LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoSunset = LinearGradient(colors: [.yellow, .orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoSea = LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoBlue = LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoStreet = LinearGradient(colors: [.green, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let photoNight = LinearGradient(colors: [.gray, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
}
