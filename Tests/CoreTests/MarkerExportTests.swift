import XCTest
@testable import AlphaSubCore

final class MarkerExportTests: XCTestCase {

    private var sample: [MarkerExportItem] {
        [
            MarkerExportItem(timeSeconds: 3610.0, name: "Fix typo", comment: "wrong spelling", color: "Red"),
            MarkerExportItem(timeSeconds: 3600.0, name: "Start", comment: "", color: "Blue"),
        ]
    }

    func testEDLIsSortedAndCarriesResolveMarkerNote() {
        let edl = MarkerExport.edl(markers: sample, frameRate: .fps25)
        XCTAssertTrue(edl.hasPrefix("TITLE: AlphaSub Markers"))
        XCTAssertTrue(edl.contains("FCM: NON-DROP FRAME"))
        // Sorted by time → the 01:00:00:00 marker comes first.
        let startIdx = edl.range(of: "01:00:00:00")!.lowerBound
        let laterIdx = edl.range(of: "01:00:10:00")!.lowerBound
        XCTAssertLessThan(startIdx, laterIdx)
        // Resolve marker convention: colour + name + duration.
        XCTAssertTrue(edl.contains("|C:ResolveColorRed |M:Fix typo |D:1"))
        XCTAssertTrue(edl.contains("|C:ResolveColorBlue |M:Start |D:1"))
        // Comment surfaced as a readable EDL comment line.
        XCTAssertTrue(edl.contains("* wrong spelling"))
    }

    func testPremiereCSVHeaderAndRows() {
        let csv = MarkerExport.premiereCSV(markers: sample, frameRate: .fps25)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.first, "Marker Name,Description,In,Out,Duration,Marker Type")
        // First data row is the earliest marker at 01:00:00:00.
        XCTAssertTrue(lines[1].contains("Start"))
        XCTAssertTrue(lines[1].contains("01:00:00:00"))
        XCTAssertTrue(lines[1].hasSuffix("Comment"))
    }

    func testFCPXMLContainsMarkers() {
        let xml = MarkerExport.fcpxml(markers: sample, frameRate: .fps25, totalDurationSeconds: 3700)
        XCTAssertTrue(xml.contains("<fcpxml version=\"1.11\">"))
        XCTAssertTrue(xml.contains("<marker "))
        XCTAssertTrue(xml.contains("value=\"Fix typo\""))
        XCTAssertTrue(xml.contains("note=\"wrong spelling\""))
        // Marker at 3600s → 3600*2400 = 8640000/2400s.
        XCTAssertTrue(xml.contains("start=\"8640000/2400s\""))
    }

    func testEmptyLabelFallsBackToMarker() {
        let items = [MarkerExportItem(timeSeconds: 3600, name: "", comment: "", color: "Green")]
        let edl = MarkerExport.edl(markers: items, frameRate: .fps25)
        XCTAssertTrue(edl.contains("|M:Marker |D:1"))
    }

    func testCSVEscapesCommas() {
        let items = [MarkerExportItem(timeSeconds: 3600, name: "a, b", comment: "c \"d\"", color: "Blue")]
        let csv = MarkerExport.premiereCSV(markers: items, frameRate: .fps25)
        XCTAssertTrue(csv.contains("\"a, b\""))
        XCTAssertTrue(csv.contains("\"c \"\"d\"\"\""))
    }
}
