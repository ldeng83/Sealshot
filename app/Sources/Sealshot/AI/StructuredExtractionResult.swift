import Foundation

/// One type's worth of extracted data, rendered for display/copy.
struct ExtractedGroup: Equatable { let title: String; let body: String }

/// Pure mapping from StructuredItems to ordered, non-empty display groups.
enum StructuredExtractionResult {

    static func isEmpty(_ items: StructuredItems) -> Bool {
        items.tables.isEmpty && items.contacts.isEmpty && items.codeBlocks.isEmpty
            && items.formFields.isEmpty && items.urls.isEmpty && items.emails.isEmpty
            && items.phones.isEmpty && items.addresses.isEmpty && items.money.isEmpty
            && items.dates.isEmpty && items.stackTraces.isEmpty
    }

    static func groups(from items: StructuredItems) -> [ExtractedGroup] {
        var out: [ExtractedGroup] = []
        if !items.tables.isEmpty {
            out.append(ExtractedGroup(title: "Tables",
                body: items.tables.map(markdownTable).joined(separator: "\n\n")))
        }
        if !items.contacts.isEmpty {
            out.append(ExtractedGroup(title: "Contacts",
                body: items.contacts.map(contactBlock).joined(separator: "\n\n")))
        }
        if !items.codeBlocks.isEmpty {
            out.append(ExtractedGroup(title: "Code",
                body: items.codeBlocks.map(codeBlock).joined(separator: "\n\n")))
        }
        if !items.formFields.isEmpty {
            out.append(ExtractedGroup(title: "Fields",
                body: items.formFields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")))
        }
        if !items.urls.isEmpty {
            out.append(ExtractedGroup(title: "URLs", body: bullets(items.urls)))
        }
        if !items.emails.isEmpty {
            out.append(ExtractedGroup(title: "Emails", body: bullets(items.emails)))
        }
        if !items.phones.isEmpty {
            out.append(ExtractedGroup(title: "Phones", body: bullets(items.phones)))
        }
        if !items.addresses.isEmpty {
            out.append(ExtractedGroup(title: "Addresses", body: bullets(items.addresses)))
        }
        if !items.money.isEmpty {
            out.append(ExtractedGroup(title: "Money", body: bullets(items.money)))
        }
        if !items.dates.isEmpty {
            out.append(ExtractedGroup(title: "Dates", body: bullets(items.dates)))
        }
        if !items.stackTraces.isEmpty {
            out.append(ExtractedGroup(title: "Stack Traces",
                body: items.stackTraces.joined(separator: "\n\n")))
        }
        return out
    }

    static func copyAllText(_ groups: [ExtractedGroup]) -> String {
        groups.map { "## \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    // MARK: formatters
    static func markdownTable(_ t: StructuredTable) -> String {
        let header = "| " + t.headers.joined(separator: " | ") + " |"
        let sep = "| " + t.headers.map { _ in "---" }.joined(separator: " | ") + " |"
        let rows = t.rows.map { "| " + $0.joined(separator: " | ") + " |" }
        return ([header, sep] + rows).joined(separator: "\n")
    }

    private static func contactBlock(_ c: StructuredContact) -> String {
        var lines: [String] = []
        if !c.name.isEmpty { lines.append(c.name) }
        let comms = [c.email, c.phone].filter { !$0.isEmpty }.joined(separator: " · ")
        if !comms.isEmpty { lines.append(comms) }
        let org = [c.organization, c.title].filter { !$0.isEmpty }.joined(separator: " — ")
        if !org.isEmpty { lines.append(org) }
        return lines.joined(separator: "\n")
    }

    private static func codeBlock(_ c: StructuredCode) -> String {
        "```\(c.language)\n\(c.code)\n```"
    }

    private static func bullets(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }
}
