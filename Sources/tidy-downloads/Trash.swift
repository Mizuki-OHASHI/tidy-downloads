import Foundation

enum Trash {
    /// Move an item to the user's Trash (recoverable), returning its new URL.
    @discardableResult
    static func move(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
