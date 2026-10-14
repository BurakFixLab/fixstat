import Testing
@testable import MacSensors

@Suite struct AmbientLightSMCTests {
    @Test func alvChannels() {
        // MacBookPro14,1 in room light: ALV0 = 01 80 00cf 0015 000bdb36.
        let bytes: [UInt8] = [0x01, 0x80, 0x00, 0xcf, 0x00, 0x15, 0x00, 0x0b, 0xdb, 0x36]
        #expect(AmbientLightSensor.channels(alv: bytes).map { [$0.0, $0.1] } == [207, 21])
        // The second sensor slot (ALV1) of the same Mac: all zero, not valid.
        #expect(AmbientLightSensor.channels(alv: [UInt8](repeating: 0, count: 10)) == nil)
    }
}
