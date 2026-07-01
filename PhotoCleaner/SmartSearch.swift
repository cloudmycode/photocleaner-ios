import CryptoKit
import Foundation
import Photos
import UIKit

// MARK: - Config

enum SmartSearchConfig {
    static var endpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SmartSearchEndpoint") as? String,
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static var enrichEndpoint: URL? {
        guard let search = endpoint else { return nil }
        return search.deletingLastPathComponent().appendingPathComponent("enrich-tags")
    }

    static var deviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
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

// MARK: - SearchPlan

struct SearchPlan: Decodable {
    var summary: String?
    var filters: SearchFilters?
    var must: SearchMust?
    var count: Int?
    var confidence: Double?
}

struct SearchFilters: Decodable {
    var dateRange: SearchDateRange?
    var locationBounds: [SearchLocationBound]?
    var mediaTypes: [String]?
    var assetTypes: [String]?
    var minSizeMB: Double?
    var maxSizeMB: Double?
    var minPixelWidth: Int?
    var minPixelHeight: Int?
    var hasLocation: Bool?
}

struct SearchMust: Decodable {
    var visualTagsAll: [String]?
    var sensitiveTypes: [String]?
    var ocrContainsAll: [String]?
    var searchKeywordGroups: [[String]]?
}

struct SearchDateRange: Decodable {
    var start: String?
    var end: String?
}

struct SearchLocationBound: Decodable {
    var name: String?
    var minLatitude: Double?
    var maxLatitude: Double?
    var minLongitude: Double?
    var maxLongitude: Double?
}

enum SmartSearchError: Error {
    case configurationMissing
    case unauthorized
    case network
}

// MARK: - Client

enum SmartSearchClient {
    static let availableTagsLimit = 1000

    static func fetchPlan(query: String, availableTags: [String]) async throws -> SearchPlan {
        guard let url = SmartSearchConfig.endpoint, !SmartSearchConfig.secret.isEmpty else {
            throw SmartSearchError.configurationMissing
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
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

        return try JSONDecoder().decode(SearchPlan.self, from: data)
    }

#if DEBUG
    private static func logResponse(data: Data, statusCode: Int) {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            print("[SmartSearch] response (\(statusCode)):\n\(text)")
        } else if let raw = String(data: data, encoding: .utf8) {
            print("[SmartSearch] response (\(statusCode)): \(raw)")
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

// MARK: - Tag Enrichment

enum TagEnrichmentClient {
    static let ocrSnippetLimit = 400

    struct Payload: Encodable {
        let assetId: String
        let rawTags: [String]
        let ocrSnippet: String
        let mediaType: String
        let assetTypes: [String]
    }

    struct ResultItem: Decodable {
        let assetId: String
        let enrichedTags: [String]
        let sensitiveTypes: [String]
        let searchDescription: String?
    }

    static func enrich(payloads: [Payload]) async throws -> [ResultItem] {
        guard let url = SmartSearchConfig.enrichEndpoint, !SmartSearchConfig.secret.isEmpty else {
            throw SmartSearchError.configurationMissing
        }
        guard !payloads.isEmpty else { return [] }

        let deviceID = SmartSearchConfig.deviceID
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            deviceId: deviceID,
            locale: Locale.current.identifier,
            appVersion: SmartSearchConfig.appVersion,
            buildVersion: SmartSearchConfig.buildVersion,
            items: payloads,
            sign: md5Sign(deviceID + SmartSearchConfig.secret)
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SmartSearchError.network }
#if DEBUG
        if !(200..<300).contains(http.statusCode) {
            print("[TagEnrich] HTTP \(http.statusCode) url=\(url.absoluteString)")
        }
#endif
        if http.statusCode == 401 { throw SmartSearchError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
#if DEBUG
            if let url = SmartSearchConfig.enrichEndpoint {
                print("[TagEnrich] HTTP \(http.statusCode) url=\(url.absoluteString)")
            }
#endif
            throw SmartSearchError.network
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded.items
    }

    private struct RequestBody: Encodable {
        let deviceId: String
        let locale: String
        let appVersion: String
        let buildVersion: String
        let items: [Payload]
        let sign: String
    }

    private struct ResponseBody: Decodable {
        let items: [ResultItem]
    }

    private static func md5Sign(_ raw: String) -> String {
        Insecure.MD5.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Service

enum SmartSearchService {
    static func search(query: String) async throws -> [PHAsset] {
        let store = PhotoSearchIndexStore.shared
        let availableTags = await store.topVisualTags(limit: SmartSearchClient.availableTagsLimit)
#if DEBUG
        print("[SmartSearch] availableTags (\(availableTags.count))")
#endif
        let plan = SmartSearchQueryParser.enrichPlan(
            try await SmartSearchClient.fetchPlan(query: query, availableTags: availableTags),
            originalQuery: query
        )
#if DEBUG
        if let groups = plan.must?.searchKeywordGroups, !groups.isEmpty {
            print("[SmartSearch] searchKeywordGroups: \(groups)")
        }
#endif
        let index = await store.searchIndex()

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetchResult = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }

        let entries = await store.validEntries(for: assets)
        let matched = SearchEngine.match(
            plan: plan,
            entries: entries,
            tagPostings: index.tagPostings,
            sensitivePostings: index.sensitivePostings
        )
#if DEBUG
        print("[SmartSearch] matched \(matched.count) / \(entries.count) indexed")
#endif
        let matchedIDs = Set(matched.map(\.id))
        return assets.filter { matchedIDs.contains($0.localIdentifier) }
    }
}
