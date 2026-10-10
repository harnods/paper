import Foundation
import SwiftData

/// A folder of papers. Folders nest through `parentID`; papers point at their folder by `folderID`.
/// Plain string IDs (not relationships) keep the model simple to sync.
@Model
final class Folder {
    var folderID: String = UUID().uuidString
    var name: String = ""
    var parentID: String?
    var createdAt: Date = Date()
    /// Path of the folder relative to the Paper folder in iCloud Drive; nil until it's created there.
    var syncedPath: String?

    init(name: String, parentID: String?) {
        self.folderID = UUID().uuidString
        self.name = name
        self.parentID = parentID
        self.createdAt = Date()
    }
}
