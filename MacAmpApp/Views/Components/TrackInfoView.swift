import SwiftUI
import AppKit

/// Read-only File Info dialog for the current track, modeled on Winamp's
/// classic File Info window. The left side is a labeled grid of edit fields
/// (read-only for now); the right side is two read-only text boxes — Format
/// Info and Replay Gain — whose contents follow Winamp's templated lines.
struct TrackInfoView: View {
    @Environment(AudioPlayer.self) private var audioPlayer
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var info: FileInfo?
    @State private var fields = FieldRegistry()

    private let labelWidth: CGFloat = 78

    /// The track resolved when the dialog opened (selected playlist item, else
    /// the playing track).
    private var target: Track? { settings.trackInfoTrack }

    private var currentURL: URL? { target?.url }

    private var isStream: Bool {
        if case .radioStation = playbackCoordinator.currentSource { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: currentURL != nil ? 660 : 380)
        .task(id: currentURL) { await load() }
    }

    // MARK: - Loading

    private func load() async {
        guard let url = currentURL else { info = nil; return }
        info = nil
        let loaded = await MetadataLoader.loadFileInfo(from: url)
        if currentURL == url { info = loaded }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let url = currentURL {
            pathField(url.path)
        } else if isStream {
            pathField(playbackCoordinator.displayTitle)
        }
    }

    private func pathField(_ text: String) -> some View {
        Fieldset {
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if currentURL != nil {
            HStack(alignment: .top, spacing: 16) {
                metadataGroup
                VStack(alignment: .leading, spacing: 12) {
                    formatInfoGroup
                    replayGainGroup
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        } else if isStream {
            Fieldset(title: "Format Info") {
                textBox(streamFormatText, height: 60)
            }
            Text("Stream playback — some metadata may be unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No track or stream loaded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }

    // MARK: - Metadata fields

    private var metadataGroup: some View {
        Fieldset(title: "Metadata", width: 320) {
            VStack(alignment: .leading, spacing: 6) {
                // Three equal-width fields share the row; with the BPM field
                // last, its right edge lands on the column's right edge (where
                // the Title/Album fields end), and nothing overflows the box.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    primaryLabel("Track #")
                    valueField(info?.trackNumber, key: "Track #")
                    inlineLabel("Disc #")
                    valueField(info?.discNumber, key: "Disc #")
                    inlineLabel("BPM")
                    valueField(info?.bpm, key: "BPM")
                }
                row("Title", info?.title ?? target?.title)
                row("Artist", info?.artist ?? target?.artist)
                row("Album", info?.album)
                row("Album Artist", info?.albumArtist)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    primaryLabel("Year")
                    valueField(info?.year, key: "Year", width: 48)
                    inlineLabel("Genre")
                    valueField(info?.genre, key: "Genre")
                }
                row("Comment", info?.comment, multiline: true)
                row("Composer", info?.composer)
                row("Publisher", info?.publisher)
            }
            .padding(.vertical, 2)
        }
    }

    /// A single-field row: label in the shared label column, field filling the
    /// rest. The label column keeps every primary field on one left edge.
    @ViewBuilder
    private func row(_ label: String, _ value: String?, multiline: Bool = false) -> some View {
        HStack(alignment: multiline ? .top : .firstTextBaseline, spacing: 8) {
            primaryLabel(label)
            valueField(value, key: label, multiline: multiline)
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: labelWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture { fields.handle(text).selectAll() }
    }

    private func inlineLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
            .contentShape(Rectangle())
            .onTapGesture { fields.handle(text).selectAll() }
    }

    @ViewBuilder
    private func valueField(_ value: String?, key: String, width: CGFloat? = nil, multiline: Bool = false) -> some View {
        let box = ReadOnlyField(text: value ?? "", lineBreak: multiline ? .byWordWrapping : .byTruncatingTail, multiline: multiline, handle: fields.handle(key))
        if let width {
            box.frame(width: width, height: 20)
        } else {
            box.frame(maxWidth: .infinity).frame(height: multiline ? 46 : 20)
        }
    }

    // MARK: - Format Info / Replay Gain text boxes

    private var formatInfoGroup: some View {
        Fieldset(title: "Format Info") {
            textBox(formatInfoText, height: 150)
        }
    }

    private var replayGainGroup: some View {
        Fieldset(title: "Replay Gain") {
            textBox(replayGainText, height: 44)
        }
    }

    private func textBox(_ text: String, height: CGFloat) -> some View {
        ReadOnlyField(text: text, lineBreak: .byWordWrapping, multiline: true)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.vertical, 2)
    }

    // MARK: - Templated text

    /// Format Info lines, following Winamp's `GetFileDescription` order and
    /// strings. A line is present only when its datum is available.
    private var formatInfoText: String {
        guard let info else { return "" }
        var lines: [String] = []
        if let b = info.payloadSizeBytes { lines.append("Payload Size: \(b) bytes") }
        if let o = info.headerOffsetBytes { lines.append("Header found at: \(o) bytes") }
        if let len = info.lengthSeconds { lines.append("Length: \(Int(len)) seconds") }
        if let name = info.formatName {
            lines.append(info.isMPEG ? name : "Format: \(name)")
        }
        if let kbps = info.bitrateKbps {
            if let frames = info.frameCount {
                lines.append("\(kbps) kbps, \(frames) frames")
            } else {
                lines.append("\(kbps) kbps")
            }
        }
        if let hz = info.sampleRateHz {
            let mode = info.channelMode ?? channelWord(info.channelCount)
            lines.append(mode.map { "\(hz) Hz \($0)" } ?? "\(hz) Hz")
        }
        if let crc = info.crc, let copyrighted = info.copyrighted {
            lines.append("CRC: \(yesNo(crc)), Copyrighted: \(yesNo(copyrighted))")
        }
        if let original = info.original, let emphasis = info.emphasis {
            lines.append("Original: \(yesNo(original)), Emphasis: \(emphasis)")
        }
        return lines.joined(separator: "\n")
    }

    private var replayGainText: String {
        guard info != nil else { return "" }
        return "Track Gain: \(info?.trackGain ?? "not present")\nAlbum Gain: \(info?.albumGain ?? "not present")"
    }

    private var streamFormatText: String {
        var lines: [String] = []
        if audioPlayer.bitrate > 0 { lines.append("\(audioPlayer.bitrate) kbps") }
        if audioPlayer.sampleRate > 0 {
            let count = audioPlayer.channelCount
            let mode = count == 1 ? "Mono" : count == 2 ? "Stereo" : count > 0 ? "\(count) channels" : nil
            lines.append(mode.map { "\(audioPlayer.sampleRate) Hz \($0)" } ?? "\(audioPlayer.sampleRate) Hz")
        }
        return lines.joined(separator: "\n")
    }

    private func yesNo(_ value: Bool) -> String { value ? "Yes" : "No" }

    private func channelWord(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "Mono" : count == 2 ? "Stereo" : "\(count) channels"
    }
}

/// A bordered box with an optional title, drawn entirely in SwiftUI. Every box
/// in the dialog uses this one container, so their borders all sit at the same
/// frame edge and their left edges align by construction — unlike `GroupBox`,
/// whose border inset differs between titled and untitled boxes.
private struct Fieldset<Content: View>: View {
    var title: String?
    var width: CGFloat?
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, width: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.width = width
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            content()
                .padding(8)
                // Size the box itself, then wrap it in the border — so a fixed
                // width never fights an outer frame and shift the box left/right.
                .frame(width: width, alignment: .topLeading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.22)))
        }
    }
}

/// A native, read-only `NSTextField` styled as an edit field: bezeled, white
/// background, selectable, non-editable. Used for the metadata fields and the
/// Format Info / Replay Gain text boxes.
private struct ReadOnlyField: NSViewRepresentable {
    let text: String
    var lineBreak: NSLineBreakMode = .byTruncatingTail
    var multiline = false
    var handle: FieldHandle?

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        handle?.field = tf
        tf.isEditable = false
        tf.isSelectable = true
        tf.isBezeled = true
        tf.bezelStyle = .squareBezel
        tf.drawsBackground = true
        tf.backgroundColor = .textBackgroundColor
        tf.font = .systemFont(ofSize: 11)
        tf.focusRingType = .none
        tf.usesSingleLineMode = !multiline
        tf.lineBreakMode = lineBreak
        tf.cell?.lineBreakMode = lineBreak
        tf.cell?.wraps = multiline
        tf.cell?.isScrollable = false
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tf.setContentHuggingPriority(multiline ? .defaultLow : .defaultHigh, for: .vertical)
        tf.stringValue = text
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        handle?.field = tf
        if tf.stringValue != text { tf.stringValue = text }
    }
}

/// Holds a weak reference to a field's `NSTextField` so its label can select the
/// field's text on click. Selection is a no-op when the field is empty.
private final class FieldHandle {
    weak var field: NSTextField?

    func selectAll() {
        guard let field, !field.stringValue.isEmpty else { return }
        field.selectText(nil)
    }
}

/// Vends one stable `FieldHandle` per label, so a label click reaches the same
/// field across view updates.
private final class FieldRegistry {
    private var handles: [String: FieldHandle] = [:]

    func handle(_ key: String) -> FieldHandle {
        if let existing = handles[key] { return existing }
        let handle = FieldHandle()
        handles[key] = handle
        return handle
    }
}

#Preview {
    let audioPlayer = AudioPlayer()
    let streamPlayer = StreamPlayer()
    return TrackInfoView()
        .environment(audioPlayer)
        .environment(PlaybackCoordinator(audioPlayer: audioPlayer, streamPlayer: streamPlayer))
        .environment(AppSettings.instance())
}
