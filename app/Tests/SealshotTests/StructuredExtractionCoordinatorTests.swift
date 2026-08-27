import XCTest
@testable import Sealshot

final class StructuredExtractionCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTable(_ id: Int) -> StructuredTable {
        StructuredTable(headers: ["Col\(id)A", "Col\(id)B"], rows: [["r\(id)1a", "r\(id)1b"]])
    }

    private func makeDoc(urls: [String] = [],
                         dates: [String] = [],
                         emails: [String] = [],
                         phones: [String] = [],
                         addresses: [String] = [],
                         money: [String] = [],
                         nativeTables: [StructuredTable] = []) -> DocumentData {
        DocumentData(urls: urls, dates: dates, emails: emails,
                     phones: phones, addresses: addresses, money: money,
                     nativeTables: nativeTables)
    }

    // MARK: - Status: .ok

    func testTablesAndDataOnly_statusOK() {
        let geo = [makeTable(1)]
        let doc = makeDoc(urls: ["https://example.com"])

        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: doc, docError: nil,
            entities: nil, entityError: nil
        )

        XCTAssertEqual(status, .ok)
        XCTAssertEqual(items.tables, geo)
        XCTAssertEqual(items.urls, ["https://example.com"])
    }

    func testNoInputNoErrors_statusOK() {
        let (_, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: nil, docError: nil,
            entities: nil, entityError: nil
        )
        XCTAssertEqual(status, .ok)
    }

    // MARK: - Status: .partial

    func testDocError_withGeometryTables_statusPartial() {
        let geo = [makeTable(1)]
        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: nil, docError: "VNError",
            entities: nil, entityError: nil
        )

        guard case .partial(let reason) = status else {
            return XCTFail("Expected .partial, got \(status)")
        }
        XCTAssertFalse(reason.isEmpty, "Partial reason must describe the error")
        XCTAssertEqual(items.tables, geo)
    }

    func testEntityError_withDocData_statusPartial() {
        let doc = makeDoc(emails: ["a@b.com"])
        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: doc, docError: nil,
            entities: nil, entityError: "NERTimeout"
        )

        guard case .partial(let reason) = status else {
            return XCTFail("Expected .partial, got \(status)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(items.emails, ["a@b.com"])
    }

    func testBothErrors_withSomeOutput_statusPartial() {
        let geo = [makeTable(2)]
        let (_, status) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: nil, docError: "DocFailed",
            entities: nil, entityError: "EntityFailed"
        )

        guard case .partial = status else {
            return XCTFail("Expected .partial since geometry tables exist")
        }
    }

    // MARK: - Status: .failed

    func testDocError_noOtherOutput_statusFailed() {
        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: nil, docError: "crashInVision",
            entities: nil, entityError: nil
        )

        guard case .failed(let reason) = status else {
            return XCTFail("Expected .failed, got \(status)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(StructuredExtractionResult.isEmpty(items),
                      "Items must be empty when everything failed")
    }

    func testBothErrors_noOutput_statusFailed() {
        let (_, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: nil, docError: "DocCrash",
            entities: nil, entityError: "EntityCrash"
        )
        guard case .failed = status else {
            return XCTFail("Expected .failed when no output at all")
        }
    }

    // MARK: - Deduplication

    func testNativeTableEqualToGeometry_notDoubleAdded() {
        let shared = makeTable(1)
        let geo = [shared]
        let doc = makeDoc(nativeTables: [shared])

        let (items, _) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: doc, docError: nil,
            entities: nil, entityError: nil
        )

        XCTAssertEqual(items.tables.count, 1,
                       "Identical geometry + native table must be deduped to 1")
        XCTAssertEqual(items.tables.first, shared)
    }

    func testNativeTablesDifferentFromGeometry_allAdded() {
        let geoTable = makeTable(1)
        let nativeTable = makeTable(2)
        let geo = [geoTable]
        let doc = makeDoc(nativeTables: [nativeTable])

        let (items, _) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: doc, docError: nil,
            entities: nil, entityError: nil
        )

        XCTAssertEqual(items.tables.count, 2)
        XCTAssertTrue(items.tables.contains(geoTable))
        XCTAssertTrue(items.tables.contains(nativeTable))
    }

    func testNativeTablesPartialOverlap_dedupeCorrectly() {
        let shared = makeTable(1)
        let extra = makeTable(3)
        let geo = [shared]
        let doc = makeDoc(nativeTables: [shared, extra])

        let (items, _) = StructuredExtractionCoordinator.merge(
            geometryTables: geo, doc: doc, docError: nil,
            entities: nil, entityError: nil
        )

        XCTAssertEqual(items.tables.count, 2,
                       "shared counted once, extra counted once")
        XCTAssertTrue(items.tables.contains(shared))
        XCTAssertTrue(items.tables.contains(extra))
    }

    // MARK: - DocumentData fields

    func testDocDataFields_populatedInItems() {
        let doc = makeDoc(
            urls: ["https://a.com"],
            dates: ["2026-06-21"],
            emails: ["x@y.com"],
            phones: ["+1-800-555-0199"],
            addresses: ["1 Infinite Loop"],
            money: ["$42.00"]
        )

        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: doc, docError: nil,
            entities: nil, entityError: nil
        )

        XCTAssertEqual(status, .ok)
        XCTAssertEqual(items.urls, doc.urls)
        XCTAssertEqual(items.dates, doc.dates)
        XCTAssertEqual(items.emails, doc.emails)
        XCTAssertEqual(items.phones, doc.phones)
        XCTAssertEqual(items.addresses, doc.addresses)
        XCTAssertEqual(items.money, doc.money)
    }

    // MARK: - Entities fold-in

    func testEntities_foldedIntoItems() {
        let contact = StructuredContact(name: "Alice", email: "alice@example.com",
                                        phone: "", organization: "ACME", title: "CTO")
        var entities = StructuredItems()
        entities.contacts = [contact]
        entities.formFields = [StructuredField(label: "Name", value: "Alice")]

        let (items, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: nil, docError: nil,
            entities: entities, entityError: nil
        )

        XCTAssertEqual(status, .ok)
        XCTAssertEqual(items.contacts, [contact])
        XCTAssertEqual(items.formFields.count, 1)
    }

    func test_merge_keyValues_foldIntoFormFields_andDedup() {
        let kv = [StructuredField(label: "Status", value: "Active"),
                  StructuredField(label: "ID", value: "7")]
        let entities = StructuredItems(formFields: [
            StructuredField(label: "Status", value: "Active"),   // duplicate of a kv pair
            StructuredField(label: "Dept", value: "Eng"),
        ])
        let (items, _) = StructuredExtractionCoordinator.merge(
            geometryTables: [], keyValues: kv, doc: nil, docError: nil,
            entities: entities, entityError: nil)
        XCTAssertEqual(items.formFields, [
            StructuredField(label: "Status", value: "Active"),
            StructuredField(label: "ID", value: "7"),
            StructuredField(label: "Dept", value: "Eng"),
        ])
    }

    func testEntitiesEntityError_entityDataIgnored_statusPartialOrFailed() {
        // When entityError is set and entities is nil, no entity data contributes.
        // With no other output → .failed; with geometry → .partial.
        let (_, status) = StructuredExtractionCoordinator.merge(
            geometryTables: [], doc: nil, docError: nil,
            entities: nil, entityError: "Timeout"
        )
        // entityError alone with no output: entityError doesn't trigger failed by itself
        // (only docError+no-output → failed). Entity error with other output → partial.
        // Entity error alone with no other output → partial (some pipeline ran, one tier failed).
        // The brief says .failed when "document step errored AND nothing else produced output".
        // Entity-only error with no output → partial (a tier failed, no crash of the whole doc step).
        guard case .partial = status else {
            return XCTFail("Expected .partial for entity-only error with no output, got \(status)")
        }
    }

    // MARK: - tableTier selection

    // Token layout: two columns at x≈0.12 and x≈0.22 (gap 0.06 < minGap 0.12 → one region),
    // two rows at midY≈0.105 and midY≈0.205. Geometry path finds 2 rows × 2 columns → 1 table.
    private func makeTierTokens() -> [LayoutToken] {
        [
            LayoutToken(text: "A", rect: CGRect(x: 0.10, y: 0.10, width: 0.04, height: 0.01)),
            LayoutToken(text: "B", rect: CGRect(x: 0.20, y: 0.10, width: 0.04, height: 0.01)),
            LayoutToken(text: "1", rect: CGRect(x: 0.10, y: 0.20, width: 0.04, height: 0.01)),
            LayoutToken(text: "2", rect: CGRect(x: 0.20, y: 0.20, width: 0.04, height: 0.01)),
        ]
    }

    func test_tableTier_emptyBoxes_fallsBackToGeometry() {
        let tokens = makeTierTokens()
        let viaFallback = StructuredExtractionCoordinator.tableTier(
            boxes: [], tokens: tokens, tolerance: 0.02, columnSeparation: 0.04)
        let geometry = TableReconstructor.buildTables(
            tokens, tolerance: 0.02, minGap: 0.12, columnSeparation: 0.04)
        XCTAssertEqual(viaFallback, geometry)
        XCTAssertFalse(viaFallback.isEmpty)
    }

    func test_tableTier_withBoxes_usesDetection() {
        let tokens = makeTierTokens()
        // Box covers all four tokens (midX in [0.12, 0.22], midY in [0.105, 0.205]).
        let boxes = [CGRect(x: 0.05, y: 0.05, width: 0.25, height: 0.25)]
        let tables = StructuredExtractionCoordinator.tableTier(
            boxes: boxes, tokens: tokens, tolerance: 0.02, columnSeparation: 0.04)
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0].headers, ["A", "B"])
    }
}
