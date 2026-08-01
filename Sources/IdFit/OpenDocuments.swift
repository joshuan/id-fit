import Foundation

/// Every document window that is currently open.
///
/// One window is one folder, so the app itself owns no document — but it still
/// has to reach them: a folder arriving from Finder needs to know whether it
/// is already open somewhere, and quitting has to ask each window in turn.
///
/// The references are weak and nothing is ever unregistered by hand. A window
/// that closes lets go of its store, which drops out of here by itself —
/// whereas hanging that on the view's disappearing removed stores that were
/// still very much alive, SwiftUI being free to take a view down and put an
/// identical one back up.
@MainActor
final class OpenDocuments {
    static let shared = OpenDocuments()

    private struct Weak {
        weak var store: DocumentStore?
    }

    private var registered: [Weak] = []

    /// Making a window is something only SwiftUI can do, so a window lends the
    /// app the ability. The action outlives the view that handed it over.
    var openWindow: ((URL) -> Void)?

    var stores: [DocumentStore] {
        registered.compactMap(\.store)
    }

    func register(_ store: DocumentStore) {
        registered.removeAll { $0.store == nil }
        guard !registered.contains(where: { $0.store === store }) else { return }
        registered.append(Weak(store: store))
    }

    func window(showing folder: URL) -> DocumentStore? {
        let wanted = folder.standardizedFileURL.resolvingSymlinksInPath()
        return stores.first {
            $0.folderURL?.standardizedFileURL.resolvingSymlinksInPath() == wanted
        }
    }

    /// Asks every window about work that was never written out. One "Cancel"
    /// stops whatever was about to happen.
    func confirmClosingAll() -> Bool {
        for store in stores where !store.confirmDiscardingChanges() {
            return false
        }
        return true
    }

    func saveAll() {
        for store in stores {
            store.saveImmediately()
        }
    }
}
