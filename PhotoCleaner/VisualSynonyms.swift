import Foundation

/// 倒排查询前扩展同义词（组内 OR）
enum VisualSynonyms {
    static func expand(_ tag: String) -> Set<String> {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }

        switch key {
        case "person", "people", "human":
            return ["person", "people", "human"]
        case "beach", "sea", "ocean", "coast", "shore":
            return ["beach", "sea", "ocean", "coast", "shore"]
        case "cat", "kitten", "feline":
            return ["cat", "kitten", "feline"]
        case "dog", "canine":
            return ["dog", "canine"]
        case "car", "vehicle", "automobile", "conveyance", "sportscar":
            return ["car", "vehicle", "automobile", "conveyance", "sportscar"]
        case "food", "meal", "dish":
            return ["food", "meal", "dish"]
        default:
            return [key]
        }
    }
}
