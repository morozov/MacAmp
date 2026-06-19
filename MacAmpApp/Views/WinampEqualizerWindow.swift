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
    @State private var keyMonitor: Any?

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
        
        // Titlebar buttons
        static let shadeButton = CGPoint(x: 254, y: 3) 
        static let closeButton = CGPoint(x: 264, y: 3)

        // Shade-strip slider wells
        static let shadeVolume = CGPoint(x: 61, y: 4)
        static let shadeVolumeWidth: CGFloat = 97
        static let shadeBalance = CGPoint(x: 164, y: 4)
        static let shadeBalanceWidth: CGFloat = 43
        
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
            if !settings.isEqualizerWindowShaded {
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
                buildTitlebarButtons(shaded: false)

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
            height: settings.isEqualizerWindowShaded ? WinampSizes.equalizerShade.height : WinampSizes.equalizer.height,
            alignment: .topLeading
        )
        .scaleEffect(
            settings.isDoubleSizeMode ? 2.0 : 1.0,
            anchor: .topLeading
        )
        .frame(
            width: settings.isDoubleSizeMode ? WinampSizes.equalizer.width * 2 : WinampSizes.equalizer.width,
            height: settings.isEqualizerWindowShaded
                ? (settings.isDoubleSizeMode ? WinampSizes.equalizerShade.height * 2 : WinampSizes.equalizerShade.height)
                : (settings.isDoubleSizeMode ? WinampSizes.equalizer.height * 2 : WinampSizes.equalizer.height),
            alignment: .topLeading
        )
        .fixedSize()  // Lock measured size so background sees final geometry
        .background(Color.black) // Must be AFTER fixedSize to see scaled dimensions
        .onAppear { installKeyMonitor() }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }

    /// Installs a key monitor that handles the equalizer's bare-key bindings
    /// while the equalizer window is key, consuming the event so it does not
    /// fall through to the global transport keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === WindowCoordinator.shared?.eqWindow else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty,
                  let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let action = EqualizerWindowHotkeys.action(forKey: chars) else {
                return event
            }
            dispatcher.perform(action)
            return nil
        }
    }
    
    /// The buttons are part of the titlebar bitmap; only the pressed sprite is drawn.
    @ViewBuilder
    private func buildTitlebarButtons(shaded: Bool) -> some View {
        SkinHitButton(pressedSprite: shaded ? "EQ_MINIMIZE_BUTTON_ACTIVE" : maximizePressedSprite, width: 9, height: 9) {
            dispatcher.perform(.shadeEqualizerWindow)
        }
        .at(EQCoords.shadeButton)

        SkinHitButton(pressedSprite: shaded ? "EQ_SHADE_CLOSE_BUTTON_ACTIVE" : "EQ_CLOSE_BUTTON_ACTIVE", width: 9, height: 9) {
            dispatcher.perform(.toggleEqualizerWindow)
        }
        .at(EQCoords.closeButton)
    }

    /// EQ_EX.BMP is optional; without it the pressed shade button comes from EQMAIN.BMP.
    private var maximizePressedSprite: String {
        skinManager.currentSkin?.loadedSheets.contains("EQ_EX") == true
            ? "EQ_MAXIMIZE_BUTTON_ACTIVE" : "EQ_MAXIMIZE_BUTTON_ACTIVE_FALLBACK"
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
            .accessibilityIdentifier("MacAmp.EQ.OnOff")
            .accessibilityValue(audioPlayer.isEqOn ? "on" : "off")
            .at(EQCoords.onButton)

            Button(action: { dispatcher.perform(.toggleEqualizerAuto) }) {
                let spriteKey = audioPlayer.eqAutoEnabled ? "EQ_AUTO_BUTTON_SELECTED" : "EQ_AUTO_BUTTON"
                SimpleSpriteImage(spriteKey, width: 32, height: 12)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityIdentifier("MacAmp.EQ.Auto")
            .accessibilityValue(audioPlayer.eqAutoEnabled ? "on" : "off")
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
        ZStack(alignment: .topLeading) {
            WinampTitlebarDragHandle(windowKind: .equalizer, size: CGSize(width: 275, height: 14)) {
                SimpleSpriteImage(isWindowActive ? "EQ_SHADE_BACKGROUND_SELECTED" : "EQ_SHADE_BACKGROUND",
                                  width: 275, height: 14)
            }

            buildShadeSlider(value: Double(audioPlayer.volume), width: EQCoords.shadeVolumeWidth,
                             thumbPrefix: "EQ_SHADE_VOLUME_SLIDER",
                             set: { playbackCoordinator.setVolume(Float($0)) },
                             commit: { playbackCoordinator.commitVolume() })
                .at(EQCoords.shadeVolume)

            buildShadeSlider(value: Double(audioPlayer.balance + 1) / 2, width: EQCoords.shadeBalanceWidth,
                             thumbPrefix: "EQ_SHADE_BALANCE_SLIDER",
                             set: { value in
                                 let balance = Float(value * 2 - 1)
                                 playbackCoordinator.setBalance(abs(balance) < 0.12 ? 0 : balance)
                             },
                             commit: { playbackCoordinator.commitBalance() })
                .at(EQCoords.shadeBalance)

            buildTitlebarButtons(shaded: true)
        }
    }

    /// Only the 3×7 thumb is drawn; its variant follows which third `value` (0...1) is in.
    private func buildShadeSlider(value: Double, width: CGFloat, thumbPrefix: String,
                                  set: @escaping (Double) -> Void, commit: @escaping () -> Void) -> some View {
        let variant = value < 1.0 / 3 ? "LEFT" : value < 2.0 / 3 ? "CENTER" : "RIGHT"
        return ZStack(alignment: .topLeading) {
            SimpleSpriteImage("\(thumbPrefix)_\(variant)", width: 3, height: 7)
                .offset(x: (width - 3) * value)
                .allowsHitTesting(false)
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { set(min(max($0.location.x / geo.size.width, 0), 1)) }
                            .onEnded { _ in commit() }
                    )
            }
        }
        .frame(width: width, height: 7, alignment: .topLeading)
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
