import AppKit

/// A best-effort capture of a pasteboard's contents so a transient programmatic
/// copy (the paste-on-finalize in "Overlay + paste" mode) can be undone afterwards.
///
/// Captures every representation present on each pasteboard item as raw `Data`.
/// Promised/lazy content with no data yet, and exotic multi-type edge cases, are
/// out of scope — the common copy/paste types (string, RTF, HTML, file URLs,
/// images) round-trip faithfully. `Sendable` value type so it can cross the
/// off-main injector queue.
nonisolated struct PasteboardSnapshot: Sendable {
    /// `NSPasteboard.changeCount` at capture time. Lets a caller tell whether
    /// anything else (a fresh user copy, or the target's own write) has touched the
    /// board since — in which case restoring would clobber newer content.
    let changeCount: Int
    /// One entry per pasteboard item: a map of UTI type string → its data.
    let items: [[String: Data]]
}

/// Thin wrapper over `NSPasteboard`. `copy` backs the history "copy" action (main
/// actor); `save`/`restore`/`setStringForPaste` back the paste-on-finalize
/// insertion mode and are `nonisolated` so `PasteInjector` can call them off the
/// main actor on its serial queue.
@MainActor
enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    /// Snapshot every representation currently on `pb`. Defaults to the general
    /// pasteboard; tests pass a private one to avoid clobbering the user's clipboard.
    nonisolated static func save(from pb: NSPasteboard = .general) -> PasteboardSnapshot {
        let items: [[String: Data]] = (pb.pasteboardItems ?? []).map { item in
            var map: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type.rawValue] = data
                }
            }
            return map
        }
        return PasteboardSnapshot(changeCount: pb.changeCount, items: items)
    }

    /// Restore a previously captured snapshot, rebuilding each item's
    /// representations. Returns the resulting `changeCount`.
    @discardableResult
    nonisolated static func restore(_ snapshot: PasteboardSnapshot, to pb: NSPasteboard = .general) -> Int {
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.compactMap { map in
            guard !map.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return pb.changeCount
    }

    /// Replace the pasteboard with a single plain-string item for an imminent paste.
    /// Returns the new `changeCount` so the caller can detect later writes before
    /// restoring.
    @discardableResult
    nonisolated static func setStringForPaste(_ string: String, to pb: NSPasteboard = .general) -> Int {
        pb.clearContents()
        pb.setString(string, forType: .string)
        return pb.changeCount
    }
}
