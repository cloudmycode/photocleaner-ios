import Foundation

/// 本地检索：倒排交集 → filters → 按时间截断
enum SearchEngine {
    static func match(
        plan: SearchPlan,
        entries: [String: PhotoSearchIndexEntry],
        tagPostings: [String: Set<String>],
        sensitivePostings: [String: Set<String>]
    ) -> [PhotoSearchIndexEntry] {
        let indexedIDs = Set(entries.keys)
        guard !indexedIDs.isEmpty else { return [] }

        let must = plan.must ?? SearchMust()
        var ids = intersectGroups(
            visualTags: must.visualTagsAll ?? [],
            sensitiveTypes: must.sensitiveTypes ?? [],
            indexedIDs: indexedIDs,
            tagPostings: tagPostings,
            sensitivePostings: sensitivePostings
        )

        for text in must.ocrContainsAll ?? [] {
            let needle = text.lowercased()
            guard !needle.isEmpty else { continue }
            ids = ids.filter { id in
                entries[id]?.searchableOCRText.lowercased().contains(needle) == true
            }
        }

        let limit = max(1, min(plan.count ?? 1000, 1000))
        return ids
            .compactMap { entries[$0] }
            .filter { passesFilters($0, filters: plan.filters) }
            .sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func intersectGroups(
        visualTags: [String],
        sensitiveTypes: [String],
        indexedIDs: Set<String>,
        tagPostings: [String: Set<String>],
        sensitivePostings: [String: Set<String>]
    ) -> Set<String> {
        var result: Set<String>?

        for tag in visualTags {
            let group = unionPostingIDs(for: tag, postings: tagPostings)
            result = result.map { $0.intersection(group) } ?? group
        }
        for type in sensitiveTypes {
            let group = sensitivePostings[type] ?? []
            result = result.map { $0.intersection(group) } ?? group
        }

        let base = result ?? indexedIDs
        return base.intersection(indexedIDs)
    }

    private static func unionPostingIDs(
        for tag: String,
        postings: [String: Set<String>]
    ) -> Set<String> {
        var ids = Set<String>()
        for synonym in VisualSynonyms.expand(tag) {
            if let set = postings[synonym] {
                ids.formUnion(set)
            }
        }
        return ids
    }

    private static func passesFilters(
        _ entry: PhotoSearchIndexEntry,
        filters: SearchFilters?
    ) -> Bool {
        guard let filters else { return true }

        if let range = filters.dateRange, !matchesDateRange(entry.creationDate, range: range) {
            return false
        }

        if let bounds = filters.locationBounds, !bounds.isEmpty {
            guard let lat = entry.latitude, let lon = entry.longitude else {
                return filters.hasLocation != true
            }
            let inBounds = bounds.contains { bound in
                guard let minLat = bound.minLatitude, let maxLat = bound.maxLatitude,
                      let minLon = bound.minLongitude, let maxLon = bound.maxLongitude else {
                    return false
                }
                return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
            }
            if !inBounds { return false }
        } else if filters.hasLocation == true {
            guard entry.latitude != nil, entry.longitude != nil else { return false }
        }

        if let types = filters.mediaTypes, !types.isEmpty, !types.contains(entry.mediaType) {
            return false
        }
        if let types = filters.assetTypes, !types.isEmpty {
            let entryTypes = Set(entry.assetTypes)
            guard types.contains(where: { entryTypes.contains($0) }) else { return false }
        }
        if let minMB = filters.minSizeMB {
            if entry.storageBytes < Int64(minMB * 1024 * 1024) { return false }
        }
        if let maxMB = filters.maxSizeMB {
            if entry.storageBytes > Int64(maxMB * 1024 * 1024) { return false }
        }
        if let minWidth = filters.minPixelWidth, entry.pixelWidth < minWidth { return false }
        if let minHeight = filters.minPixelHeight, entry.pixelHeight < minHeight { return false }
        return true
    }

    private static func matchesDateRange(_ date: Date?, range: SearchDateRange) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        if let start = range.start, let startDate = dayFormatter.date(from: start),
           calendar.startOfDay(for: date) < calendar.startOfDay(for: startDate) {
            return false
        }
        if let end = range.end, let endDate = dayFormatter.date(from: end),
           calendar.startOfDay(for: date) > calendar.startOfDay(for: endDate) {
            return false
        }
        return true
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
