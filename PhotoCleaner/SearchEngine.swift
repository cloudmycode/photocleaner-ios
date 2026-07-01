import Foundation

/// 本地检索：关键词描述匹配 / 倒排交集 → filters → 按时间截断
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
        let keywordGroups = normalizedKeywordGroups(must.searchKeywordGroups ?? [])
        let visualTags = must.visualTagsAll ?? []
        let sensitiveTypes = must.sensitiveTypes ?? []

        var ids: Set<String>?

        if !keywordGroups.isEmpty {
            ids = matchKeywordGroups(keywordGroups, entries: entries, indexedIDs: indexedIDs)
        }

        if !visualTags.isEmpty || !sensitiveTypes.isEmpty {
            let visualIDs = intersectGroups(
                visualTags: visualTags,
                sensitiveTypes: sensitiveTypes,
                indexedIDs: indexedIDs,
                tagPostings: tagPostings,
                sensitivePostings: sensitivePostings
            )
            ids = ids.map { $0.intersection(visualIDs) } ?? visualIDs
        }

        guard var matchedIDs = ids else { return [] }

        for text in must.ocrContainsAll ?? [] {
            let needle = text.lowercased()
            guard !needle.isEmpty else { continue }
            matchedIDs = matchedIDs.filter { id in
                entries[id]?.searchableOCRText.lowercased().contains(needle) == true
            }
        }

        let limit = max(1, min(plan.count ?? 1000, 1000))
        return matchedIDs
            .compactMap { entries[$0] }
            .filter { passesFilters($0, filters: plan.filters) }
            .sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizedKeywordGroups(_ groups: [[String]]) -> [[String]] {
        groups.compactMap { group in
            let words = group
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            return words.isEmpty ? nil : words
        }
    }

    /// 组内任一关键词命中（OR），组间全部满足（AND）
    private static func matchKeywordGroups(
        _ groups: [[String]],
        entries: [String: PhotoSearchIndexEntry],
        indexedIDs: Set<String>
    ) -> Set<String> {
        var matched = Set<String>()
        for id in indexedIDs {
            guard let entry = entries[id] else { continue }
            let haystack = entry.searchableDescriptionText.lowercased()
            guard !haystack.isEmpty else { continue }
            let allGroupsHit = groups.allSatisfy { group in
                group.contains { haystack.contains($0) }
            }
            if allGroupsHit {
                matched.insert(id)
            }
        }
        return matched
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

        let base = result ?? []
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
