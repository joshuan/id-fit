import AppKit
import Foundation

/// Keeping the app up to date, which is the app's business and not any one
/// document's.
///
/// It asks in AppKit panels rather than in a window's own alert: with several
/// documents open, an alert attached to a window would either appear in the
/// wrong one or appear in all of them.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private static let lastCheckKey = "lastUpdateCheck"

    /// The newest release known to exist. A notification acted on much later
    /// still has to know what it was about.
    private(set) var latest: UpdateChecker.Release?
    private var isInstalling = false

    /// Settles every open document before the app is replaced and restarted.
    /// Answers false to call the whole thing off.
    var confirmRestart: () -> Bool = { true }

    /// The look on launch: silent unless there is something to say, and at
    /// most once a day. That interval is also the whole of "Later" — nothing
    /// is recorded, so the next launch a day or more on asks again.
    func checkIfDue() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard UpdateSchedule.isDue(lastCheck: last, now: Date()) else { return }
        await check(userInitiated: false)
    }

    func checkNow() async {
        await check(userInitiated: true)
    }

    private func check(userInitiated: Bool) async {
        let current = UpdateChecker.runningVersion
        do {
            let outcome = try await UpdateChecker.check(currentVersion: current)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            switch outcome {
            case .upToDate:
                if userInitiated {
                    UpdatePrompt.report("ID Fit \(current) is the latest version.")
                }
            case .available(let release):
                latest = release
                if userInitiated {
                    // A question asked out loud gets its answer on the spot,
                    // not a banner that may be switched off entirely.
                    offer(release, currentVersion: current)
                } else if await UpdateNotifier.post(
                    release: release, currentVersion: current
                ) == false {
                    offer(release, currentVersion: current)
                }
            }
        } catch {
            // A check nobody asked for stays quiet when it fails. Being
            // offline is not news, and the app works offline anyway.
            if userInitiated {
                UpdatePrompt.report("Could not check for updates: \(error.localizedDescription)")
            }
        }
    }

    /// Puts the question in front of somebody, wherever the news came from.
    func offer(_ release: UpdateChecker.Release, currentVersion: String = UpdateChecker.runningVersion) {
        switch UpdatePrompt.ask(version: release.version, currentVersion: currentVersion) {
        case .install:
            Task { await install(release) }
        case .openPage:
            NSWorkspace.shared.open(release.page)
        case .later:
            break
        }
    }

    /// Brings the news back up — for a notification tapped after the app was
    /// restarted, when nothing about it is remembered any more.
    func showLatest() async {
        if let latest {
            offer(latest)
        } else {
            await checkNow()
        }
    }

    func installLatest() async {
        guard let latest else { return await checkNow() }
        await install(latest)
    }

    /// Replaces the app with the new release and restarts it. A refusal
    /// anywhere along the way, or no network at all, leaves the installed copy
    /// exactly as it was.
    private func install(_ release: UpdateChecker.Release) async {
        guard !isInstalling else { return }
        // Everything open is about to be restarted, so settle it first — and
        // let the answer be "not now".
        guard confirmRestart() else { return }

        isInstalling = true
        defer { isInstalling = false }
        do {
            try await UpdateInstaller.install(release)
            NSApp.terminate(nil)
        } catch {
            UpdatePrompt.report("""
                Could not install the update: \(error.localizedDescription)

                ID Fit \(UpdateChecker.runningVersion) is still installed and \
                unharmed. You can download \(release.version) from the release \
                page instead.
                """)
        }
    }
}

/// The panels the updater speaks through.
@MainActor
enum UpdatePrompt {
    enum Answer {
        case install
        case openPage
        case later
    }

    static func ask(version: String, currentVersion: String) -> Answer {
        let alert = NSAlert()
        alert.messageText = "ID Fit \(version) is available"
        alert.informativeText = """
            You have \(currentVersion). Installing replaces this copy and \
            restarts it; anything unsaved is settled first.
            """
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .openPage
        default: return .later
        }
    }

    static func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Check for Updates"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
