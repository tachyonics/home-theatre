import Foundation
import XCTest
@testable import HomeTheatreCore

final class NFOInspectionTests: XCTestCase {
    private func inspect(_ xml: String) throws -> NFOInspection {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ht-inspect-\(UUID().uuidString).nfo")
        try Data(xml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try NFOInspection.load(contentsOf: url)
    }

    func testFieldsKeepDocumentOrderAndCarryRoles() throws {
        let inspection = try inspect("""
        <episodedetails>
          <title>Rose</title>
          <season>1</season>
          <episode>1</episode>
          <lockdata>true</lockdata>
        </episodedetails>
        """)

        XCTAssertEqual(inspection.rootName, "episodedetails")
        XCTAssertEqual(inspection.fields.map(\.name), ["title", "season", "episode", "lockdata"])
        XCTAssertEqual(inspection.fields.map(\.role), [.other, .identity, .identity, .lock])
    }

    /// Aliasing tags silently discard one another; the inspection says which.
    func testSupersededAliasIsMarked() throws {
        let inspection = try inspect("""
        <episodedetails>
          <airsbefore_season>3</airsbefore_season>
          <displayseason>5</displayseason>
        </episodedetails>
        """)

        let airs = try XCTUnwrap(inspection.fields.first { $0.name == "airsbefore_season" })
        let display = try XCTUnwrap(inspection.fields.first { $0.name == "displayseason" })

        XCTAssertEqual(airs.status, .superseded)
        XCTAssertEqual(display.status, .effective)
        XCTAssertTrue(airs.isIgnored)
        XCTAssertFalse(display.isIgnored)
    }

    /// A non-positive ordering value looks authoritative but does nothing.
    func testNonPositiveOrderingValueIsMarkedDiscarded() throws {
        let inspection = try inspect("""
        <episodedetails>
          <displayseason>1</displayseason>
          <displayepisode>0</displayepisode>
        </episodedetails>
        """)

        XCTAssertEqual(inspection.fields.first { $0.name == "displayepisode" }?.status, .discardedNonPositive)
        XCTAssertEqual(inspection.fields.first { $0.name == "displayseason" }?.status, .effective)
    }

    /// A discarded value must not let an earlier alias win by default.
    func testEarlierAliasStillLosesToADiscardedLaterOne() throws {
        let inspection = try inspect("""
        <episodedetails>
          <displayseason>4</displayseason>
          <airsafter_season>0</airsafter_season>
        </episodedetails>
        """)

        XCTAssertEqual(inspection.fields.first { $0.name == "displayseason" }?.status, .effective)
        XCTAssertEqual(inspection.fields.first { $0.name == "airsafter_season" }?.status, .discardedNonPositive)
    }

    func testRawTextIsPreserved() throws {
        let xml = "<season><seasonnumber>2</seasonnumber></season>"
        let inspection = try inspect(xml)
        XCTAssertEqual(inspection.rawText, xml)
        XCTAssertEqual(inspection.fields.first?.role, .identity)
    }

    func testNestedElementsAreFlattenedWithDepth() throws {
        let inspection = try inspect("""
        <tvshow>
          <displayorder>dvd</displayorder>
          <ratings><rating name="tvdb"><value>8.5</value></rating></ratings>
        </tvshow>
        """)

        XCTAssertEqual(inspection.fields.first { $0.name == "displayorder" }?.role, .ordering)
        XCTAssertEqual(inspection.fields.first { $0.name == "value" }?.depth, 2)
    }
}
