import AppKit

/// Thin wrapper over the general pasteboard for the history "copy" action.
@MainActor
enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}
