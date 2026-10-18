import Foundation

struct ModDependency: Decodable {
    var UniqueID: String
    var MinimumVersion: String?
    var IsRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case UniqueID, UniqueId, MinimumVersion, IsRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        UniqueID = try container.decodeIfPresent(String.self, forKey: .UniqueID) ??
                   container.decodeIfPresent(String.self, forKey: .UniqueId) ?? ""
        MinimumVersion = try container.decodeIfPresent(String.self, forKey: .MinimumVersion)
        IsRequired = try container.decodeIfPresent(Bool.self, forKey: .IsRequired)
    }
}

struct ContentPackReference: Decodable {
    var UniqueID: String
    var MinimumVersion: String?

    enum CodingKeys: String, CodingKey {
        case UniqueID, UniqueId, MinimumVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        UniqueID = try container.decodeIfPresent(String.self, forKey: .UniqueID) ??
                   container.decodeIfPresent(String.self, forKey: .UniqueId) ?? ""
        MinimumVersion = try container.decodeIfPresent(String.self, forKey: .MinimumVersion)
    }
}

struct ModManifest: Decodable {
    var Name: String
    var Author: String
    var Version: String
    var Description: String?
    var UniqueID: String
    var UpdateKeys: [String]?
    var Dependencies: [ModDependency]?
    var ContentPackFor: ContentPackReference?

    enum CodingKeys: String, CodingKey {
        case Name, Author, Version, Description, UniqueID, UniqueId, UpdateKeys, Dependencies, ContentPackFor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Name = try container.decodeIfPresent(String.self, forKey: .Name) ?? "Unknown Mod"
        Author = try container.decodeIfPresent(String.self, forKey: .Author) ?? "Unknown Author"
        Description = try container.decodeIfPresent(String.self, forKey: .Description)

        // Handle UniqueID vs UniqueId
        if let id = try container.decodeIfPresent(String.self, forKey: .UniqueID) {
            UniqueID = id
        } else if let id = try container.decodeIfPresent(String.self, forKey: .UniqueId) {
            UniqueID = id
        } else {
            UniqueID = UUID().uuidString
        }

        UpdateKeys = try container.decodeIfPresent([String].self, forKey: .UpdateKeys)
        Dependencies = try container.decodeIfPresent([ModDependency].self, forKey: .Dependencies)
        ContentPackFor = try container.decodeIfPresent(ContentPackReference.self, forKey: .ContentPackFor)

        // Version can be a string "1.0.0" or an object {"MajorVersion": 1, "MinorVersion": 0}
        if let vString = try? container.decode(String.self, forKey: .Version) {
            Version = vString
        } else {
            Version = "Unknown"
        }
    }
}

struct ModEntry: Identifiable {
    var id: String { manifest.UniqueID }
    var manifest: ModManifest
    var folderPath: String
    var hasUpdate: Bool = false
    var suggestedVersion: String? = nil
    var suggestedUpdateURL: URL? = nil
    var sourceID: String? = nil
}
