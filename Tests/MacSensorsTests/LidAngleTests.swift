import Testing
@testable import MacSensors

@Suite struct LidAngleTests {
    @Test func reportOneHoldsTheNineBitAngle() {
        // Report ID 1, then 9 bits little endian: 0x6e = 110°, 0x0168 = 360°.
        #expect(LidAngleSensor.angle(report: [0x01, 0x6e, 0x00]) == 110)
        #expect(LidAngleSensor.angle(report: [0x01, 0x68, 0x01]) == 360)
        // The upper bits of the second byte belong to the next field.
        #expect(LidAngleSensor.angle(report: [0x01, 0x6e, 0xfe]) == 110)
        #expect(LidAngleSensor.angle(report: [0x02, 0x6e, 0x00]) == nil)
        #expect(LidAngleSensor.angle(report: [0x01, 0xff, 0x01]) == nil)
    }

    @Test func everyMacBookFromM2HasTheSensorButThe13InchProM2() {
        for model in ["Mac14,2", "Mac15,12", "Mac15,3", "Mac16,12", "Mac17,6"] {
            #expect(LidAngleSensor.expected(model: model, notebook: true), "\(model)")
        }
        for model in ["Mac14,7", "MacBookAir10,1", "MacBookPro17,1", "MacBookPro18,3", "MacBookPro15,2"] {
            #expect(!LidAngleSensor.expected(model: model, notebook: true), "\(model)")
        }
        // A Mac mini M2 has an identifier of the same form.
        #expect(!LidAngleSensor.expected(model: "Mac14,3", notebook: false))
    }
}
