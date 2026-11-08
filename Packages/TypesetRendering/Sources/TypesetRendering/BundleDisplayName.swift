import Foundation

public extension Bundle {
    /// Never hardcode the app name in UI strings — read it from the bundle so
    /// renaming stays a single xcconfig edit. Shared by the app and the
    /// rendering surface (e.g. `ImageBlockView`'s sandbox access prompt).
    var displayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Untitled"
    }
}
