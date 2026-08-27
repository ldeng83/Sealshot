import Foundation

/// Pure, deterministic grouping of flat GLiNER entity detections into
/// `StructuredContact`s and leftover `StructuredField`s.
enum EntityGrouping {

    // MARK: - Label constants

    private static let labelPersonName   = "person name"
    private static let labelOrganization = "organization"
    private static let labelJobTitle     = "job title"
    private static let labelEmail        = "email address"
    private static let labelPhone        = "phone number"

    /// The set of labels that attach to a contact (other than person name itself).
    private static let contactAttachableLabels: Set<String> = [
        labelOrganization, labelJobTitle, labelEmail, labelPhone,
    ]

    // MARK: - Public API

    /// Group person-name detections with nearby org/title/email/phone (by order
    /// in the list) into `StructuredContact`s. Detections are `(label, text)` in
    /// transcript reading order. Labels are GLiNER strings, e.g.
    /// `"person name"`, `"organization"`, `"job title"`, `"email address"`, `"phone number"`.
    ///
    /// Rules:
    /// - Each `"person name"` detection opens a new contact bucket.
    /// - Subsequent attachable detections fill that bucket (first-wins per field).
    /// - Duplicate attachable values that lose first-wins are kept as formFields.
    /// - Attachable detections that appear **before any person name** are orphans → formFields.
    /// - Completely unknown labels → formFields regardless of position.
    static func groupContacts(
        _ detections: [(label: String, text: String)]
    ) -> (contacts: [StructuredContact], formFields: [StructuredField]) {

        // Mutable accumulator for the current contact being built.
        var currentName:   String? = nil
        var currentOrg:    String  = ""
        var currentTitle:  String  = ""
        var currentEmail:  String  = ""
        var currentPhone:  String  = ""

        var contacts:   [StructuredContact] = []
        var formFields: [StructuredField]   = []

        /// Flush the current contact bucket (if any) into `contacts`.
        func flush() {
            guard let name = currentName else { return }
            contacts.append(StructuredContact(
                name: name, email: currentEmail, phone: currentPhone,
                organization: currentOrg, title: currentTitle
            ))
            currentName  = nil
            currentOrg   = ""
            currentTitle = ""
            currentEmail = ""
            currentPhone = ""
        }

        for detection in detections {
            let label = detection.label
            let text  = detection.text

            switch label {
            case labelPersonName:
                flush()
                currentName = text

            case labelOrganization:
                if currentName != nil {
                    if currentOrg.isEmpty { currentOrg = text }
                    else { formFields.append(StructuredField(label: humanLabel(label), value: text)) }
                } else {
                    formFields.append(StructuredField(label: humanLabel(label), value: text))
                }

            case labelJobTitle:
                if currentName != nil {
                    if currentTitle.isEmpty { currentTitle = text }
                    else { formFields.append(StructuredField(label: humanLabel(label), value: text)) }
                } else {
                    formFields.append(StructuredField(label: humanLabel(label), value: text))
                }

            case labelEmail:
                if currentName != nil {
                    if currentEmail.isEmpty { currentEmail = text }
                    else { formFields.append(StructuredField(label: humanLabel(label), value: text)) }
                } else {
                    formFields.append(StructuredField(label: humanLabel(label), value: text))
                }

            case labelPhone:
                if currentName != nil {
                    if currentPhone.isEmpty { currentPhone = text }
                    else { formFields.append(StructuredField(label: humanLabel(label), value: text)) }
                } else {
                    formFields.append(StructuredField(label: humanLabel(label), value: text))
                }

            default:
                // Unknown label → formField regardless of context.
                formFields.append(StructuredField(label: humanLabel(label), value: text))
            }
        }

        flush()
        return (contacts: contacts, formFields: formFields)
    }

    // MARK: - Helpers

    /// Convert a GLiNER label like `"email address"` to a title-cased display
    /// string like `"Email Address"` for use as a `StructuredField` label.
    private static func humanLabel(_ glinerLabel: String) -> String {
        glinerLabel
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
