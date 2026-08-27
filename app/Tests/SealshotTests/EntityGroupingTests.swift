import XCTest
@testable import Sealshot

final class EntityGroupingTests: XCTestCase {

    // MARK: - Single contact: person + trailing attachables

    func test_singlePersonWithAllFields() {
        let detections: [(label: String, text: String)] = [
            (label: "person name",    text: "Jane Doe"),
            (label: "organization",   text: "Acme Corp"),
            (label: "job title",      text: "Engineer"),
            (label: "email address",  text: "jane@acme.com"),
            (label: "phone number",   text: "+1-555-0100"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertEqual(result.contacts.count, 1)
        let c = result.contacts[0]
        XCTAssertEqual(c.name,         "Jane Doe")
        XCTAssertEqual(c.organization, "Acme Corp")
        XCTAssertEqual(c.title,        "Engineer")
        XCTAssertEqual(c.email,        "jane@acme.com")
        XCTAssertEqual(c.phone,        "+1-555-0100")
        XCTAssertTrue(result.formFields.isEmpty)
    }

    // MARK: - Two people: correct split

    func test_twoPeopleCorrectlySplit() {
        let detections: [(label: String, text: String)] = [
            (label: "person name",   text: "Alice"),
            (label: "email address", text: "alice@example.com"),
            (label: "person name",   text: "Bob"),
            (label: "email address", text: "bob@example.com"),
            (label: "phone number",  text: "555-9999"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertEqual(result.contacts.count, 2)
        let alice = result.contacts[0]
        let bob   = result.contacts[1]
        XCTAssertEqual(alice.name,  "Alice")
        XCTAssertEqual(alice.email, "alice@example.com")
        XCTAssertEqual(alice.phone, "")          // bob's phone must NOT bleed into alice
        XCTAssertEqual(bob.name,   "Bob")
        XCTAssertEqual(bob.email,  "bob@example.com")
        XCTAssertEqual(bob.phone,  "555-9999")
        XCTAssertTrue(result.formFields.isEmpty)
    }

    // MARK: - Orphan: known-label detection with no preceding person name → formField

    func test_orphanOrgBecomesFormField() {
        let detections: [(label: String, text: String)] = [
            (label: "organization", text: "Orphan LLC"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertTrue(result.contacts.isEmpty)
        XCTAssertEqual(result.formFields.count, 1)
        XCTAssertEqual(result.formFields[0].label, "Organization")
        XCTAssertEqual(result.formFields[0].value, "Orphan LLC")
    }

    func test_orphanEmailAndPhoneBeforeAnyPerson() {
        let detections: [(label: String, text: String)] = [
            (label: "email address", text: "orphan@email.com"),
            (label: "phone number",  text: "555-0000"),
            (label: "person name",   text: "Charlie"),
            (label: "organization",  text: "Widgets Inc"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        // The two detections before the first person become form fields
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].name,         "Charlie")
        XCTAssertEqual(result.contacts[0].organization, "Widgets Inc")
        XCTAssertEqual(result.contacts[0].email, "")
        XCTAssertEqual(result.contacts[0].phone, "")
        XCTAssertEqual(result.formFields.count, 2)
        XCTAssertEqual(result.formFields[0].label, "Email Address")
        XCTAssertEqual(result.formFields[0].value, "orphan@email.com")
        XCTAssertEqual(result.formFields[1].label, "Phone Number")
        XCTAssertEqual(result.formFields[1].value, "555-0000")
    }

    // MARK: - Unknown label → formField

    func test_unknownLabelBecomesFormField() {
        let detections: [(label: String, text: String)] = [
            (label: "person name",  text: "Dana"),
            (label: "website url",  text: "https://dana.io"),
            (label: "unknown type", text: "mystery value"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].name, "Dana")
        XCTAssertEqual(result.formFields.count, 2)
        XCTAssertEqual(result.formFields[0].label, "Website Url")
        XCTAssertEqual(result.formFields[0].value, "https://dana.io")
        XCTAssertEqual(result.formFields[1].label, "Unknown Type")
        XCTAssertEqual(result.formFields[1].value, "mystery value")
    }

    // MARK: - First-wins for duplicate fields within same contact

    func test_firstWinsOnDuplicateField() {
        let detections: [(label: String, text: String)] = [
            (label: "person name",   text: "Eve"),
            (label: "email address", text: "first@eve.com"),
            (label: "email address", text: "second@eve.com"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].email, "first@eve.com")
        // The second email should still be captured as a formField (not silently dropped)
        XCTAssertEqual(result.formFields.count, 1)
        XCTAssertEqual(result.formFields[0].label, "Email Address")
        XCTAssertEqual(result.formFields[0].value, "second@eve.com")
    }

    // MARK: - Empty input

    func test_emptyInputReturnsEmpty() {
        let result = EntityGrouping.groupContacts([])
        XCTAssertTrue(result.contacts.isEmpty)
        XCTAssertTrue(result.formFields.isEmpty)
    }

    // MARK: - Person with no attachables

    func test_personWithNoAttachablesProducesContactWithEmptyFields() {
        let detections: [(label: String, text: String)] = [
            (label: "person name", text: "Solo"),
        ]
        let result = EntityGrouping.groupContacts(detections)
        XCTAssertEqual(result.contacts.count, 1)
        XCTAssertEqual(result.contacts[0].name,  "Solo")
        XCTAssertEqual(result.contacts[0].email, "")
        XCTAssertEqual(result.contacts[0].phone, "")
        XCTAssertEqual(result.contacts[0].organization, "")
        XCTAssertEqual(result.contacts[0].title, "")
        XCTAssertTrue(result.formFields.isEmpty)
    }
}
