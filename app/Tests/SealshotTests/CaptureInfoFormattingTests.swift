import XCTest
import AppKit
@testable import Sealshot

/// Pure formatting for the left Info pane's metadata + object summary.
final class CaptureInfoFormattingTests: XCTestCase {

    private func ann(_ geometry: Geometry) -> Annotation {
        Annotation(geometry: geometry,
                   style: Style(strokeColor: SerializableColor(NSColor.black), strokeWidth: 2))
    }

    // MARK: - objectSummary

    func test_objectSummary_empty_isNil() {
        XCTAssertNil(CaptureInfoFormatting.objectSummary([]))
    }

    func test_objectSummary_singleArrow_singular() {
        let s = CaptureInfoFormatting.objectSummary([ann(.arrow(start: .zero, end: .zero))])
        XCTAssertEqual(s, "1 object — 1 line arrow")
    }

    func test_objectSummary_pluralizesAndCountsPerType() {
        let s = CaptureInfoFormatting.objectSummary([
            ann(.arrow(start: .zero, end: .zero)),
            ann(.arrow(start: .zero, end: .zero)),
            ann(.text(rect: .zero, runs: [])),
        ])
        XCTAssertEqual(s, "3 objects — 2 line arrows, 1 text")
    }

    /// Breakdown follows a fixed canonical type order regardless of array order.
    func test_objectSummary_usesCanonicalTypeOrder() {
        let s = CaptureInfoFormatting.objectSummary([
            ann(.text(rect: .zero, runs: [])),
            ann(.rectangle(rect: .zero)),
            ann(.arrow(start: .zero, end: .zero)),
        ])
        XCTAssertEqual(s, "3 objects — 1 line arrow, 1 rectangle, 1 text")
    }

    // MARK: - displayDate

    func test_displayDate_validISO_formats() {
        // The manifest's iso8601 format (with fractional seconds + offset).
        let out = CaptureInfoFormatting.displayDate(iso: "2026-06-12T16:14:00Z",
                                                    now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(out, "a valid ISO-8601 string must format")
        XCTAssertFalse(out!.isEmpty)
    }

    func test_displayDate_garbage_isNil() {
        XCTAssertNil(CaptureInfoFormatting.displayDate(iso: "not a date",
                                                       now: Date(timeIntervalSince1970: 0)))
    }
}
