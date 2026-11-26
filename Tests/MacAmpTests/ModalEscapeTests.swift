import AppKit
import Synchronization
import Testing
@testable import MacAmp

@MainActor
private final class MonitorRecords {
    private(set) var callbacks: [(NSEvent) -> NSEvent?] = []
    private(set) var active: Set<ObjectIdentifier> = []
    private(set) var removals = 0

    var registration: LocalEventMonitorRegistration {
        LocalEventMonitorRegistration(add: { _, callback in
            let token = NSObject()
            self.callbacks.append(callback)
            self.active.insert(ObjectIdentifier(token))
            return token
        }, remove: { token in
            #expect(self.active.remove(ObjectIdentifier(token as AnyObject)) != nil)
            self.removals += 1
        })
    }
}

private final class NotificationRecords: NotificationCenter, @unchecked Sendable {
    private let removals = Mutex(0)
    var removalCount: Int { removals.withLock { $0 } }

    override func removeObserver(_ observer: Any) {
        removals.withLock { $0 += 1 }
        super.removeObserver(observer)
    }
}

@MainActor
private final class ButtonAction: NSObject {
    var perform: () -> Void = {}
    @objc func invoke(_ sender: Any?) { perform() }

    func connect(_ button: NSButton) {
        button.target = self
        button.action = #selector(invoke(_:))
    }
}

@MainActor
@Suite("Modal Escape", .serialized)
struct ModalEscapeTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    }

    private func panel() -> NSPanel {
        NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    private func key(_ code: UInt16 = 53, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil,
            characters: code == 53 ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
            isARepeat: false, keyCode: code
        ))
    }

    @Test("Popup releases ownership before a synchronous action and invokes it once")
    func popupSelectionLifetime() throws {
        let parent = window()
        let popup = panel()
        let monitors = MonitorRecords()
        let notifications = NotificationRecords()
        let host = PlaylistSpritePopupHost(
            panel: popup, parentWindow: parent,
            monitors: monitors.registration, notifications: notifications
        )
        host.activate()
        defer { host.dismiss() }
        #expect(popup.parent === parent)
        #expect(!popup.isVisible && !parent.isVisible)
        #expect(monitors.active.count == 1)
        var calls = 0
        host.select {
            calls += 1
            #expect(PlaylistSpritePopupHost.current == nil)
            #expect(popup.parent == nil)
            #expect(monitors.active.isEmpty)
            #expect(monitors.removals == 1)
            #expect(notifications.removalCount == 1)
            host.select { calls += 1 }
        }
        host.select { calls += 1 }
        host.dismiss()
        #expect(calls == 1)
        #expect(monitors.removals == 1)
        #expect(notifications.removalCount == 1)
        let escape = try key()
        let callback = try #require(monitors.callbacks.first)
        #expect(callback(escape) === escape)
    }

    @Test("Popup stays alive during selection and preserves a replacement host")
    func popupRetentionAndReplacement() {
        let parent = window()
        var host: PlaylistSpritePopupHost? = PlaylistSpritePopupHost(panel: panel(), parentWindow: parent)
        weak var weakHost = host
        let select = { [weak target = host] (action: () -> Void) in target?.select(action) }
        host?.activate()
        host = nil
        let replacement = PlaylistSpritePopupHost(panel: panel(), parentWindow: parent)
        defer { replacement.dismiss() }
        select {
            #expect(weakHost != nil)
            #expect(PlaylistSpritePopupHost.current == nil)
            replacement.activate()
        }
        #expect(weakHost == nil)
        #expect(PlaylistSpritePopupHost.current === replacement)
    }

    @Test("Popup Escape belongs to its parent and leaves other windows and keys alone")
    func popupEscapeScope() throws {
        let parent = window()
        let other = window()
        let popup = panel()
        let records = MonitorRecords()
        let host = PlaylistSpritePopupHost(panel: popup, parentWindow: parent, monitors: records.registration)
        host.activate()
        defer { host.dismiss() }
        let escape = try key()
        let enter = try key(36)
        #expect(host.handle(escape, in: other) === escape)
        #expect(host.handle(escape, in: nil) === escape)
        #expect(host.handle(enter, in: parent) === enter)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            let modified = try key(modifiers: modifier)
            #expect(host.handle(modified, in: parent) === modified)
        }
        #expect(PlaylistSpritePopupHost.current === host)
        #expect(host.handle(escape, in: parent) == nil)
        #expect(records.active.isEmpty)
        #expect(PlaylistSpritePopupHost.current == nil)
    }

    @Test("Popup outside click passes through and deactivation releases registrations")
    func popupOutsideAndDeactivation() throws {
        let parent = window()
        let popup = panel()
        let records = MonitorRecords()
        let notifications = NotificationRecords()
        let host = PlaylistSpritePopupHost(
            panel: popup, parentWindow: parent, monitors: records.registration, notifications: notifications
        )
        host.activate()
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        #expect(host.handle(click, in: popup) === click)
        #expect(!records.active.isEmpty)
        #expect(host.handle(click, in: parent) === click)
        #expect(records.active.isEmpty)
        #expect(notifications.removalCount == 1)

        let next = PlaylistSpritePopupHost(
            panel: panel(), parentWindow: parent, monitors: records.registration, notifications: notifications
        )
        next.activate()
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(records.active.isEmpty)
        #expect(notifications.removalCount == 2)
        #expect(PlaylistSpritePopupHost.current == nil)
    }

    @Test("Notice Escape removes its monitor before activation and consumes only its window")
    func noticeEscapeScopeAndLifetime() throws {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        let other = window()
        let records = MonitorRecords()
        var activations = 0
        let target = ButtonAction()
        target.connect(alert.buttons[0])
        target.perform = {
            #expect(records.active.isEmpty)
            activations += 1
        }
        let cancellation = AlertEscapeCancellation(alert: alert, monitors: records.registration)
        defer { cancellation.invalidate() }
        let escape = try key()
        let enter = try key(36)
        #expect(cancellation.handle(escape, in: other) === escape)
        #expect(cancellation.handle(escape, in: nil) === escape)
        #expect(cancellation.handle(enter, in: alert.window) === enter)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            let modified = try key(modifiers: modifier)
            #expect(cancellation.handle(modified, in: alert.window) === modified)
        }
        #expect(activations == 0)
        #expect(cancellation.handle(escape, in: alert.window) == nil)
        #expect(activations == 1)
        #expect(cancellation.handle(escape, in: alert.window) === escape)
        let callback = try #require(records.callbacks.first)
        #expect(callback(escape) === escape)
        #expect(activations == 1)
        #expect(records.removals == 1)
        #expect(alert.buttons[0].keyEquivalent == "\r")
    }

    @Test("Notice presentation owns cancellation during the runner and releases before completion")
    func noticePresentationLifetime() {
        for response: NSApplication.ModalResponse in [.alertFirstButtonReturn, .abort] {
            let alert = NSAlert()
            alert.addButton(withTitle: "OK")
            let records = MonitorRecords()
            var completions = 0
            WinampAlertHelper.present(alert, monitors: records.registration, run: { received in
                #expect(received === alert)
                #expect(records.active.count == 1)
                return response
            }, completion: { result in
                #expect(result == response)
                #expect(records.active.isEmpty)
                completions += 1
            })
            #expect(completions == 1)
            #expect(records.removals == 1)
        }
    }

    @Test("Sheet presentation retains cancellation until completion then releases it")
    func noticeSheetLifetime() {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        let parent = window()
        let records = MonitorRecords()
        var finish: ((NSApplication.ModalResponse) -> Void)?
        var completions = 0
        WinampAlertHelper.present(alert, sheetFor: parent, monitors: records.registration, run: { _ in
            Issue.record("A sheet must not use the modal runner")
            return .abort
        }, beginSheet: { received, window, completion in
            #expect(received === alert)
            #expect(window === parent)
            #expect(records.active.count == 1)
            finish = completion
        }, completion: { response in
            #expect(records.active.isEmpty)
            #expect(response == .alertFirstButtonReturn)
            completions += 1
        })
        #expect(records.active.count == 1)
        #expect(completions == 0)
        finish?(.alertFirstButtonReturn)
        finish = nil
        #expect(records.removals == 1)
        #expect(completions == 1)
    }

    @Test("Add URL Cancel keeps playlist selection and playback unchanged; Return still accepts")
    func addURLCancellationAndAcceptance() throws {
        let player = AudioPlayer()
        let original = Track(url: URL(fileURLWithPath: "/original.wav"), title: "Original", artist: "", duration: 10)
        player.playlistController.addTrack(original)
        player.selectTrackForPlayback(original)
        player.currentTime = 7
        player.playbackProgress = 0.7
        let actions = PlaylistWindowActions()
        actions.selectedIndices = [0]
        let ui = PlaylistWindowInteractionState()
        ui.selectedIndices = [0]
        ui.cursorIndex = 0
        ui.anchorIndex = 0
        let wasPlaying = player.isPlaying
        let playbackState = player.playbackState
        let escape = try key()
        let enter = try key(36)
        var response: NSApplication.ModalResponse = .abort
        let target = ButtonAction()
        actions.presentAddURLPrompt(audioPlayer: player) { alert in
            let input = alert.accessoryView as? NSTextField
            input?.stringValue = "https://example.com/live"
            #expect(alert.buttons[0].keyEquivalent == "\r")
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
            target.connect(alert.buttons[1])
            target.perform = { response = .alertSecondButtonReturn }
            #expect(alert.buttons[1].performKeyEquivalent(with: escape))
            return response
        }
        #expect(response == .alertSecondButtonReturn)
        #expect(player.playlist.map(\.id) == [original.id])
        #expect(player.currentTrack?.id == original.id)
        #expect(player.playlistPosition == 1)
        #expect(player.isPlaying == wasPlaying)
        #expect(player.playbackState == playbackState)
        #expect(player.currentTime == 7 && player.playbackProgress == 0.7)
        #expect(actions.selectedIndices == [0])
        #expect(ui.selectedIndices == [0] && ui.cursorIndex == 0 && ui.anchorIndex == 0)

        actions.presentAddURLPrompt(audioPlayer: player) { alert in
            (alert.accessoryView as? NSTextField)?.stringValue = "https://example.com/live"
            target.connect(alert.buttons[0])
            target.perform = { response = .alertFirstButtonReturn }
            #expect(alert.buttons[0].performKeyEquivalent(with: enter))
            return response
        }
        #expect(player.playlist.count == 2)
        #expect(player.playlist.last?.url.absoluteString == "https://example.com/live")
        #expect(player.currentTrack?.id == original.id)
    }

    @Test("Invalid Add URL input stays rejected without presenting a modal in unit tests")
    func addURLValidation() {
        let player = AudioPlayer()
        for text in ["", "ftp://example.com/live", "not a URL"] {
            PlaylistWindowActions().presentAddURLPrompt(audioPlayer: player) { alert in
                (alert.accessoryView as? NSTextField)?.stringValue = text
                return .alertFirstButtonReturn
            }
            #expect(player.playlist.isEmpty)
        }
    }

    @Test("Escape cancels destructive choices while Return retains their default action")
    func destructiveCancellation() throws {
        let escape = try key()
        let enter = try key(36)
        for title in ["Move to Trash", "Save Anyway", "Replace", "Save"] {
            let alert = NSAlert()
            let accept = alert.addButton(withTitle: title)
            let cancel = alert.addButton(withTitle: "Cancel")
            let accepted = ButtonAction()
            let cancelled = ButtonAction()
            var accepts = 0
            var cancels = 0
            accepted.perform = { accepts += 1 }
            cancelled.perform = { cancels += 1 }
            accepted.connect(accept)
            cancelled.connect(cancel)
            #expect(!accept.performKeyEquivalent(with: escape))
            #expect(cancel.performKeyEquivalent(with: escape))
            #expect(accepts == 0 && cancels == 1)
            #expect(accept.performKeyEquivalent(with: enter))
            #expect(accepts == 1 && cancels == 1)
        }
    }
}
