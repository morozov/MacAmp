import Testing
@testable import MacAmp

@Suite("EqualizerWindowHotkeys")
struct EqualizerWindowHotkeysTests {
    @Test("N toggles the equalizer on/off, case-insensitively")
    func nTogglesEnabled() {
        #expect(EqualizerWindowHotkeys.action(forKey: "n") == .toggleEqualizerEnabled)
        #expect(EqualizerWindowHotkeys.action(forKey: "N") == .toggleEqualizerEnabled)
    }

    @Test("A toggles auto-preset")
    func aTogglesAuto() {
        #expect(EqualizerWindowHotkeys.action(forKey: "a") == .toggleEqualizerAuto)
    }

    @Test("Unmapped keys produce no action")
    func unmappedKeysReturnNil() {
        #expect(EqualizerWindowHotkeys.action(forKey: "z") == nil)
        #expect(EqualizerWindowHotkeys.action(forKey: "") == nil)
    }
}
