import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pixel-perfect recreation of Winamp's equalizer window using absolute positioning
struct WinampEqualizerWindow: View {
    @Environment(SkinManager.self) var skinManager
    @Environment(AudioPlayer.self) var audioPlayer
    @Environment(AppSettings.self) var settings
    @Environment(PlaybackCoordinator.self) var playbackCoordinator
    @Environment(WindowFocusState.self) var windowFocusState
    @Environment(UserActionDispatcher.self) var dispatcher

    @State private var showPresetPicker: Bool = false

    private var isShadeMode: Bool { settings.isEqualizerWindowShaded }

    // Computed: Is this window currently focused?
    private var isWindowActive: Bool {
        windowFocusState.isEqualizerKey
    }

    // Winamp EQ coordinate constants (CORRECTED from webamp reference)
    private struct EQCoords {
        // Preamp slider (leftmost) - CORRECTED
        static let preampSlider = CGPoint(x: 21, y: 38)
        
        // 10-band EQ sliders - CORRECTED positions from webamp  
        static let eqSliderPositions: [CGFloat] = [78, 96, 114, 132, 150, 168, 186, 204, 222, 240]
        static let eqSliderY: CGFloat = 38
        
        // ON/AUTO buttons - CORRECTED
        static let onButton = CGPoint(x: 14, y: 18)
        static let autoButton = CGPoint(x: 40, y: 18)  // Adjusted spacing
        
        // Presets button - CORRECTED
        static let presetsButton = CGPoint(x: 217, y: 18)
        
        // Titlebar buttons — EQ has only shade and close (no minimize)
        static let shadeButton = CGPoint(x: 254, y: 3)
        static let closeButton = CGPoint(x: 264, y: 3)
        
        // EQ curve graph area - CORRECTED
        static let graphArea = CGPoint(x: 86, y: 17)
    }

    private func importPresetFromFile() {
        let panel = NSOpenPanel()
        if let eqfType = UTType(filenameExtension: "eqf") {
            panel.allowedContentTypes = [eqfType]
        }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                audioPlayer.importEqfPreset(from: url)
                showPresetPicker = false
            }
        }
    }
    
    // EQ slider specs - CORRECTED to match webamp exactly
    private let sliderWidth: CGFloat = 14  // CORRECTED: Each slider is 14px wide
    private let sliderHeight: CGFloat = 62  // CORRECTED: 62px active area (not 63)
    private let thumbWidth: CGFloat = 11
    private let thumbHeight: CGFloat = 11
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if !isShadeMode {
                // Full window mode
                // Background - The EQMAIN sprite includes preamp text and frequency labels
                SimpleSpriteImage("EQ_WINDOW_BACKGROUND",
                                width: WinampSizes.equalizer.width,
                                height: WinampSizes.equalizer.height)

                // Title bar - apply .at() to drag handle itself for proper positioning
                WinampTitlebarDragHandle(windowKind: .equalizer, size: CGSize(width: 275, height: 14)) {
                    SimpleSpriteImage(isWindowActive ? "EQ_TITLE_BAR_SELECTED" : "EQ_TITLE_BAR",
                                    width: 275,
                                    height: 14)
                }
                .at(CGPoint(x: 0, y: 0))

                // Titlebar buttons (always active, never dimmed)
                buildTitlebarButtons()

                // EQ controls (dimmed briefly during stream prebuffering before bridge activates)
                Group {
                    // ON/AUTO buttons
                    buildControlButtons()

                    // Preamp slider
                    buildPreampSlider()

                    // 10-band EQ sliders
                    buildEQSliders()

                    // Presets button
                    buildPresetsButton()

                    // EQ curve visualization (simplified for now)
                    buildEQCurve()
                }
            } else {
                // Shade mode
                buildShadeMode()
            }
        }
        .frame(
            width: WinampSizes.equalizer.width,
            height: isShadeMode ? WinampSizes.equalizerShade.height : WinampSizes.equalizer.height,
            alignment: .topLeading
        )
        .scaleEffect(
            settings.isDoubleSizeMode ? 2.0 : 1.0,
            anchor: .topLeading
        )
        .frame(
            width: settings.isDoubleSizeMode ? WinampSizes.equalizer.width * 2 : WinampSizes.equalizer.width,
            height: isShadeMode
                ? (settings.isDoubleSizeMode ? WinampSizes.equalizerShade.height * 2 : WinampSizes.equalizerShade.height)
                : (settings.isDoubleSizeMode ? WinampSizes.equalizer.height * 2 : WinampSizes.equalizer.height),
            alignment: .topLeading
        )
        .fixedSize()  // Lock measured size so background sees final geometry
        .background(Color.black) // Must be AFTER fixedSize to see scaled dimensions
    }
    
    @ViewBuilder
    private func buildTitlebarButtons() -> some View {
        Group {
            Button(action: { dispatcher.perform(.shadeEqualizerWindow) }) {
                SimpleSpriteImage("MAIN_SHADE_BUTTON", width: 9, height: 9)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .at(EQCoords.shadeButton)

            Button(action: { dispatcher.perform(.toggleEqualizerWindow) }) {
                SimpleSpriteImage("MAIN_CLOSE_BUTTON", width: 9, height: 9)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .at(EQCoords.closeButton)
        }
    }

    @ViewBuilder
    private func buildControlButtons() -> some View {
        Group {
            Button(action: { dispatcher.perform(.toggleEqualizerEnabled) }) {
                let spriteKey = audioPlayer.isEqOn ? "EQ_ON_BUTTON_SELECTED" : "EQ_ON_BUTTON"
                SimpleSpriteImage(spriteKey, width: 26, height: 12)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .at(EQCoords.onButton)

            Button(action: { dispatcher.perform(.toggleEqualizerAuto) }) {
                let spriteKey = audioPlayer.eqAutoEnabled ? "EQ_AUTO_BUTTON_SELECTED" : "EQ_AUTO_BUTTON"
                SimpleSpriteImage(spriteKey, width: 32, height: 12)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .at(EQCoords.autoButton)
        }
    }
    
    @ViewBuilder
    private func buildPreampSlider() -> some View {
        WinampVerticalSlider(
            value: Binding(
                get: { audioPlayer.preamp },
                set: { audioPlayer.setPreamp(value: $0) }  // Call setPreamp to affect audio
            ),
            range: -12.0...12.0,
            width: sliderWidth,   // 14px exactly
            height: sliderHeight, // 62px exactly
            thumbWidth: thumbWidth,
            thumbHeight: thumbHeight,
            backgroundSprite: "EQ_SLIDER_BACKGROUND",
            thumbSprite: "EQ_SLIDER_THUMB",
            thumbActiveSprite: "EQ_SLIDER_THUMB_SELECTED"
        )
        .at(EQCoords.preampSlider) // x: 21, y: 38 (exact webamp position)
    }
    
    @ViewBuilder
    private func buildEQSliders() -> some View {
        // 10 EQ band sliders using EXACT webamp positions
        ForEach(0..<10, id: \.self) { bandIndex in
            WinampVerticalSlider(
                value: Binding(
                    get: { audioPlayer.eqBands[bandIndex] },
                    set: { audioPlayer.setEqBand(index: bandIndex, value: $0) }
                ),
                range: -12.0...12.0,
                width: sliderWidth,
                height: sliderHeight,
                thumbWidth: thumbWidth,
                thumbHeight: thumbHeight,
                backgroundSprite: "EQ_SLIDER_BACKGROUND",
                thumbSprite: "EQ_SLIDER_THUMB",
                thumbActiveSprite: "EQ_SLIDER_THUMB_SELECTED"
            )
            .at(CGPoint(
                x: EQCoords.eqSliderPositions[bandIndex], // Use exact positions from webamp
                y: EQCoords.eqSliderY
            ))
        }
    }
    
    @ViewBuilder
    private func buildPresetsButton() -> some View {
        Button {
            showPresetPicker.toggle()
        } label: {
            SimpleSpriteImage("EQ_PRESETS_BUTTON", width: 44, height: 12)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .popover(isPresented: $showPresetPicker, arrowEdge: .bottom) {
            EQPresetPickerView(
                builtInPresets: EQPreset.builtIn,
                userPresets: audioPlayer.userPresets,
                onSelect: { preset in
                    audioPlayer.applyEQPreset(preset)
                    showPresetPicker = false
                },
                onSave: {
                    showSavePresetDialog()
                    showPresetPicker = false
                },
                onDeleteUserPreset: { presetID in
                    audioPlayer.deleteUserPreset(id: presetID)
                },
                onImport: {
                    importPresetFromFile()
                }
            )
        }
        .at(EQCoords.presetsButton)
    }

    private func showSavePresetDialog() {
        let alert = NSAlert()
        alert.messageText = "Save EQ Preset"
        alert.informativeText = "Enter a name for this preset:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = "My Preset"
        textField.placeholderString = "Preset name"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let presetName = textField.stringValue
            audioPlayer.saveUserPreset(named: presetName)
        }
    }
    
    @ViewBuilder
    private func buildShadeMode() -> some View {
        // EQ shade mode shows a compact 275×14px bar.
        // `alignment: .topLeading` matches the full-mode ZStack so `.at(...)`
        // (which is `.offset(...)`) lands children at absolute coordinates from
        // the top-left — with the default `.center` alignment a titlebar
        // button at `.at(254, 3)` would offset 254 px right of the *center*,
        // ending up off-window and unclickable.
        ZStack(alignment: .topLeading) {
            // Shade background. The slider TRACKS for volume and balance are
            // baked into this sprite — the EQShadeSlider only renders the thumb.
            SimpleSpriteImage("EQ_SHADE_BACKGROUND", width: 275, height: 14)
                .at(CGPoint(x: 0, y: 0))

            // Compact volume + balance sliders (Webamp's `EqualizerShade.tsx`
            // mounts `<Volume id="equalizer-volume">` and
            // `<Balance id="equalizer-balance">`; CSS positions them at
            // (61, 4) 97×6 and (164, 4) 43×6 respectively).
            let volumeBinding = Binding<Float>(
                get: { audioPlayer.volume },
                set: { playbackCoordinator.setVolume($0) }
            )
            EQShadeSlider(
                value: volumeBinding,
                valueRange: 0...1,
                trackWidth: 97,
                spritePrefix: "EQ_SHADE_VOLUME_SLIDER",
                onDragEnded: { playbackCoordinator.commitVolume() }
            )
            .at(CGPoint(x: 61, y: 4))

            let balanceBinding = Binding<Float>(
                get: { audioPlayer.balance },
                set: { playbackCoordinator.setBalance($0) }
            )
            EQShadeSlider(
                value: balanceBinding,
                valueRange: -1...1,
                trackWidth: 43,
                spritePrefix: "EQ_SHADE_BALANCE_SLIDER",
                onDragEnded: { playbackCoordinator.commitBalance() }
            )
            .at(CGPoint(x: 164, y: 4))

            // Titlebar buttons
            buildTitlebarButtons()
        }
    }

    @ViewBuilder
    private func buildEQCurve() -> some View {
        // Curve is overlaid on the background sprite; don't add `.at(graphArea)`
        // inside the overlay or it'll be offset twice.
        let lineColors = skinManager.currentSkin?.eqGraphLineColors
            ?? Array(repeating: NSColor.systemGreen, count: 19)
        SimpleSpriteImage("EQ_GRAPH_BACKGROUND", width: 113, height: 19)
            .overlay(
                Image(nsImage: renderEQCurveImage(
                    bands: audioPlayer.eqBands,
                    lineColors: lineColors
                ))
                .interpolation(.none)
                .antialiased(false)
                .resizable()
                .frame(width: 113, height: 19)
            )
            .at(EQCoords.graphArea)
    }

    /// Render the 113×19 EQ preview curve. Writes RGBA bytes directly into the
    /// context buffer — `ctx.fill(1×1)` per pixel would be ~2k state changes
    /// per repaint.
    private func renderEQCurveImage(bands: [Float], lineColors: [NSColor]) -> NSImage {
        let width = 113
        let height = 19
        let bandCount = bands.count
        let maxX = width - 1
        let stride = width * 4

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = ctx.data else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        let buf = data.bindMemory(to: UInt8.self, capacity: height * stride)

        if bandCount > 1, lineColors.count == height {
            var rowBytes = [(r: UInt8, g: UInt8, b: UInt8)](
                repeating: (0, 0, 0), count: height
            )
            for i in 0..<height {
                let c = lineColors[i].usingColorSpace(.sRGB) ?? lineColors[i]
                rowBytes[i] = (
                    UInt8(clamping: Int((c.redComponent * 255).rounded())),
                    UInt8(clamping: Int((c.greenComponent * 255).rounded())),
                    UInt8(clamping: Int((c.blueComponent * 255).rounded()))
                )
            }

            // Match Webamp's percentToRange((1 - value/range) * 100, 0, GRAPH_HEIGHT - 1):
            // gain= -12 → row 18, gain= 0 → row 9, gain= +12 → row 0.
            func sampleY(at x: Int) -> Int {
                let position = Double(x) / Double(maxX) * Double(bandCount - 1)
                let lower = min(Int(position), bandCount - 2)
                let frac = CGFloat(position - Double(lower))
                let gain = CGFloat(bands[lower]) + (CGFloat(bands[lower + 1]) - CGFloat(bands[lower])) * frac
                let yDisplay = CGFloat(height - 1) * (12.0 - gain) / 24.0
                return max(0, min(height - 1, Int(yDisplay.rounded())))
            }

            var lastDisplayY = sampleY(at: 0)
            for x in 0...maxX {
                let displayY = sampleY(at: x)
                let topDisplay = min(displayY, lastDisplayY)
                let h = 1 + abs(lastDisplayY - displayY)
                for dy in 0..<h {
                    let dispRow = topDisplay + dy
                    let cgY = height - 1 - dispRow // CGContext is bottom-left.
                    let i = cgY * stride + x * 4
                    let c = rowBytes[dispRow]
                    buf[i]     = c.r
                    buf[i + 1] = c.g
                    buf[i + 2] = c.b
                    buf[i + 3] = 0xFF
                }
                lastDisplayY = displayY
            }
        }

        guard let cg = ctx.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}

#Preview {
    WinampEqualizerWindow()
        .environment(SkinManager())
        .environment(AudioPlayer())
}
