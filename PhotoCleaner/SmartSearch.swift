import CryptoKit
import Foundation
import Photos

// MARK: - Config

enum SmartSearchConfig {
    static var endpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SmartSearchEndpoint") as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static var secret: String {
        Bundle.main.object(forInfoDictionaryKey: "SmartSearchSecret") as? String ?? ""
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}

// MARK: - Models

struct SmartSearchCondition: Decodable {
    var summary: String?
    var dateRange: SmartSearchDateRange?
    var locationBounds: [SmartSearchLocationBound]?
    var mediaTypes: [String]?
    var assetTypes: [String]?
    var minSizeMB: Double?
    var maxSizeMB: Double?
    var minPixelWidth: Int?
    var minPixelHeight: Int?
    var hasLocation: Bool?
    var keywords: [String]?
    var visualConcepts: [SmartSearchVisualConcept]?
    var ocrKeywords: [String]?
    var ocrRegexes: [String]?
    var sensitiveTypes: [String]?
    var requiresOCR: Bool?
    var count: Int?
    var confidence: Double?
}

struct SmartSearchDateRange: Decodable {
    var start: String?
    var end: String?
}

struct SmartSearchLocationBound: Decodable {
    var name: String?
    var minLatitude: Double?
    var maxLatitude: Double?
    var minLongitude: Double?
    var maxLongitude: Double?
}

struct SmartSearchVisualConcept: Decodable {
    var name: String
    var matchAny: [String]
}

enum SmartSearchError: Error {
    case configurationMissing
    case unauthorized
    case network
}

// MARK: - Client

enum SmartSearchClient {
    /// 上传标签数上限；默认传本机全量去重标签，不超过此值。
    static let availableTagsLimit = 1000

    static func fetchSearchCondition(
        query: String,
        availableTags: [String]
    ) async throws -> SmartSearchCondition {
        guard let url = SmartSearchConfig.endpoint, !SmartSearchConfig.secret.isEmpty else {
            throw SmartSearchError.configurationMissing
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            query: trimmed,
            locale: Locale.current.identifier,
            appVersion: SmartSearchConfig.appVersion,
            buildVersion: SmartSearchConfig.buildVersion,
            availableTags: Array(availableTags.prefix(availableTagsLimit)),
            sign: md5Sign(trimmed + SmartSearchConfig.secret)
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SmartSearchError.network }
#if DEBUG
        logResponse(data: data, statusCode: http.statusCode)
#endif
        if http.statusCode == 401 { throw SmartSearchError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SmartSearchError.network }

        return try JSONDecoder().decode(SmartSearchCondition.self, from: data)
    }

#if DEBUG
    private static func logResponse(data: Data, statusCode: Int) {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            print("[SmartSearch] response (\(statusCode)):\n\(text)")
        } else if let raw = String(data: data, encoding: .utf8) {
            print("[SmartSearch] response (\(statusCode)): \(raw)")
        } else {
            print("[SmartSearch] response (\(statusCode)): <\(data.count) bytes>")
        }
    }
#endif

    private struct RequestBody: Encodable {
        let query: String
        let locale: String
        let appVersion: String
        let buildVersion: String
        let availableTags: [String]
        let sign: String
    }

    private static func md5Sign(_ raw: String) -> String {
        Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Matcher

enum SmartSearchMatcher {
    static func match(
        entries: [PhotoSearchIndexEntry],
        condition: SmartSearchCondition
    ) -> [PhotoSearchIndexEntry] {
        var candidates = entries.filter { passesHardFilters($0, condition: condition) }
        let concepts = condition.visualConcepts ?? []
        if !concepts.isEmpty {
            candidates = candidates.filter { entry in
                concepts.allSatisfy { concept in
                    concept.matchAny.contains { matchesKeyword($0, entry: entry) }
                }
            }
        }

        let keywords = (condition.keywords ?? []).map(normalizeTag).filter { !$0.isEmpty }
        let ocrKeywords = (condition.ocrKeywords ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        let ocrRegexes = condition.ocrRegexes ?? []
        let hasSemantic = !keywords.isEmpty || !ocrKeywords.isEmpty || !ocrRegexes.isEmpty

        let scored = candidates.map { entry -> (PhotoSearchIndexEntry, Double) in
            var score = 0.0
            for keyword in keywords where matchesKeyword(keyword, entry: entry) { score += 1 }
            for keyword in ocrKeywords where (entry.ocrText ?? "").lowercased().contains(keyword) { score += 1 }
            for pattern in ocrRegexes {
                let text = entry.ocrText ?? ""
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                    score += 1
                }
            }
            return (entry, score)
        }

        let filtered = hasSemantic ? scored.filter { $0.1 > 0 } : scored
        let limit = max(1, min(condition.count ?? 1000, 1000))
        return filtered
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return ($0.0.creationDate ?? .distantPast) > ($1.0.creationDate ?? .distantPast)
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func passesHardFilters(_ entry: PhotoSearchIndexEntry, condition: SmartSearchCondition) -> Bool {
        if let range = condition.dateRange, !matchesDateRange(entry.creationDate, range: range) { return false }

        if let bounds = condition.locationBounds, !bounds.isEmpty {
            guard let lat = entry.latitude, let lon = entry.longitude else { return condition.hasLocation != true }
            guard bounds.contains(where: { bound in
                guard let minLat = bound.minLatitude, let maxLat = bound.maxLatitude,
                      let minLon = bound.minLongitude, let maxLon = bound.maxLongitude else { return false }
                return lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
            }) else { return false }
        } else if condition.hasLocation == true {
            guard entry.latitude != nil, entry.longitude != nil else { return false }
        }

        if let types = condition.mediaTypes, !types.isEmpty, !types.contains(entry.mediaType) { return false }
        if let types = condition.assetTypes, !types.isEmpty {
            let entryTypes = Set(entry.assetTypes)
            guard types.contains(where: { entryTypes.contains($0) }) else { return false }
        }
        if let minMB = condition.minSizeMB {
            let minBytes = Int64(minMB * 1024 * 1024)
            if entry.storageBytes < minBytes { return false }
        }
        if let maxMB = condition.maxSizeMB {
            let maxBytes = Int64(maxMB * 1024 * 1024)
            if entry.storageBytes > maxBytes { return false }
        }
        if let minWidth = condition.minPixelWidth, entry.pixelWidth < minWidth { return false }
        if let minHeight = condition.minPixelHeight, entry.pixelHeight < minHeight { return false }
        if condition.requiresOCR == true, entry.ocrIndexedAt == nil { return false }
        return true
    }

    private static func matchesDateRange(_ date: Date?, range: SmartSearchDateRange) -> Bool {
        guard let date else { return false }
        let calendar = Calendar.current
        if let start = range.start, let startDate = dayFormatter.date(from: start),
           calendar.startOfDay(for: date) < calendar.startOfDay(for: startDate) { return false }
        if let end = range.end, let endDate = dayFormatter.date(from: end),
           calendar.startOfDay(for: date) > calendar.startOfDay(for: endDate) { return false }
        return true
    }

    static func matchesKeyword(_ keyword: String, entry: PhotoSearchIndexEntry) -> Bool {
        if matchesVisualTag(keyword, entry: entry) { return true }
        return (entry.ocrText ?? "").lowercased().contains(keyword.lowercased())
    }

    private static func matchesVisualTag(_ keyword: String, entry: PhotoSearchIndexEntry) -> Bool {
        let normalized = normalizeTag(keyword)
        let tags = Set((entry.visualTags ?? []).map(normalizeTag))
        guard !tags.isEmpty else { return false }
        if tags.contains(normalized) { return true }
        return tags.contains { $0.contains(normalized) || normalized.contains($0) }
    }

    private static func normalizeTag(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .joined(separator: "_")
            .lowercased()
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}

// MARK: - Service

enum SmartSearchService {
    static func search(query: String) async throws -> [PHAsset] {
        let availableTags = await PhotoSearchIndexStore.shared.topVisualTags(
            limit: SmartSearchClient.availableTagsLimit
        )
#if DEBUG
        print("[SmartSearch] availableTags (\(availableTags.count)): \(availableTags.prefix(20).joined(separator: ", "))\(availableTags.count > 20 ? ", …" : "")")
#endif
        let condition = try await SmartSearchClient.fetchSearchCondition(
            query: query,
            availableTags: availableTags
        )

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        let indexed = await PhotoSearchIndexStore.shared.validEntries(for: assets)
        let entries = assets.compactMap { indexed[$0.localIdentifier] }
        let matched = SmartSearchMatcher.match(entries: entries, condition: condition)
        let matchedIDs = Set(matched.map(\.id))
        return assets.filter { matchedIDs.contains($0.localIdentifier) }
    }
}
