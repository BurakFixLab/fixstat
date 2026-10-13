import Foundation
import Testing
@testable import MacSensors

@Suite struct InternalStorageTests {
    @Test func largestInternalContainerGivesTheSpace() {
        // `diskutil apfs list` of an M1 Air: the small iSCPreboot / Recovery containers are left out.
        let containers: [[String: Any]] = [
            ["CapacityCeiling": 524_288_000, "CapacityFree": 505_843_712],
            ["CapacityCeiling": 5_368_664_064, "CapacityFree": 2_743_513_088],
            ["CapacityCeiling": 245_107_195_904, "CapacityFree": 63_480_049_664],
        ]
        let space = InternalStorage.containerSpace(containers)
        #expect(space?.total == 245_107_195_904)
        #expect(space?.available == 63_480_049_664)
        #expect(space?.startedFromOtherDisk == true)
        #expect(InternalStorage.containerSpace([]) == nil)
    }

    @Test func spaceFromOlderReportsDecodes() throws {
        // Reports written before the field existed.
        let old = try JSONDecoder().decode(VolumeSpace.self, from: Data(#"{"total":100,"available":40}"#.utf8))
        #expect(old.startedFromOtherDisk == nil)
        #expect(old.used == 60)
    }

    @Test func startedFromTheInternalSSDKeepsTheTemporaryFolder() {
        // Unchanged behaviour when the Mac runs from its internal SSD (CI may run elsewhere).
        guard InternalStorage.startedFromInternal else { return }
        #expect(InternalStorage.testDirectory() == FileManager.default.temporaryDirectory)
    }
}
