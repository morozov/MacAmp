import AppKit

@MainActor
struct PlaylistEntryEditorFields {
    let oldValue: NSTextField
    let newValue: NSTextField
    let grid: NSGridView

    init(old: String, new: String) {
        oldValue = NSTextField(string: old)
        oldValue.isEditable = false
        oldValue.isSelectable = true
        newValue = NSTextField(string: new)
        for field in [oldValue, newValue] {
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Old"), oldValue],
            [NSTextField(labelWithString: "New"), newValue]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.autoresizingMask = [.width]
    }
}

@MainActor
final class PlaylistEntryEditor {
    private var lastTrackID: UUID?
    private var lastText: String?

    func prompt(_ track: Track, error: String?) -> String? {
        guard !UnitTestSupport.isActive else { return nil }
        let location = TrackInfoView.location(of: track)
        let fields = PlaylistEntryEditorFields(
            old: location, new: lastTrackID == track.id ? lastText ?? location : location
        )
        let alert = NSAlert()
        alert.messageText = "Edit playlist entry"
        alert.informativeText = error ?? ""
        alert.addButton(withTitle: "OK").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.layout()
        fields.grid.setFrameSize(NSSize(width: alert.window.contentView?.bounds.width ?? fields.grid.fittingSize.width,
                                       height: fields.grid.fittingSize.height))
        alert.accessoryView = fields.grid
        alert.layout()
        alert.window.initialFirstResponder = fields.newValue
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        lastTrackID = track.id
        lastText = fields.newValue.stringValue
        return lastText
    }
}
