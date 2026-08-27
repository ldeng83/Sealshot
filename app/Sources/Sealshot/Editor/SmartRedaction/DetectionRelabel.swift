import Foundation

/// Corrects the one safe label mistake the model makes: a "money amount" that is
/// actually a measurement (carries a unit). Relabels it "measurement" — never
/// drops or unredacts. Pure.
enum DetectionRelabel {
    // A digit (optional space) immediately followed by a measurement unit token.
    // Longer/prefix-overlapping units listed first (mmHg before mm; spelled forms
    // present so a trailing-\b never strips them). No currency notation matches.
    private static let measurementRegex = try! NSRegularExpression(
        pattern: #"\d[\s/]*(?:mmHg|mg|mcg|µg|ug|mL|ml|cc|kg|km|cm|mm|bpm|IU|milligrams?|micrograms?|millilit(?:er|re)s?|kilograms?|grams?|g)\b"#,
        options: [.caseInsensitive])

    static func containsMeasurementUnit(_ text: String) -> Bool {
        measurementRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Mirrors EditorState.isMoneyAmount (kept inline so this stays a pure,
    /// actor-free helper): the model emits the unmapped label "money amount".
    private static func isMoney(_ d: Detection) -> Bool {
        d.customLabel?.lowercased().contains("money") ?? false
    }

    // MARK: - Sanity reclassification (non-PII mislabeled as sensitive)
    // Conservative down-rank: relabel a precise non-PII pattern to a .contextual
    // "noise" label (timestamp/hostname/service name). EditorState.defaultKept
    // never auto-checks those, so the item stays visible but unchecked. Never drops.

    // A clock time (HH:MM) — present in log timestamps, absent from a bare date.
    // No \b anchors: an ISO time is embedded in alphanumerics (…T14:18:12Z).
    private static let clockTimeRegex = try! NSRegularExpression(pattern: #"\d{1,2}:\d{2}"#)
    static func isLogTimestamp(_ value: String) -> Bool {
        clockTimeRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    // An @host whose host part has no dot (sre@host-320, devops@workstation) — i.e.
    // not an email TLD. Plus path/URI markers. A real street address has none.
    private static let hostAtRegex = try! NSRegularExpression(pattern: #"@[^.\s@]+$"#)
    static func isHostnameOrPath(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.contains("~/") || v.contains("://") { return true }
        return hostAtRegex.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
    }

    // Lowercase, hyphenated infra name with a known suffix (auth-service, payments-api,
    // user-svc, prod-cluster, claims-service-7c9d5f6d8b). Real orgs have spaces/caps;
    // "corp" is deliberately excluded so real companies aren't suppressed.
    private static let serviceNameRegex = try! NSRegularExpression(
        pattern: #"^[a-z0-9]+-(?:api|service|svc|platform|prod|cluster|infra|gateway|worker|queue|db|cache)(?:-[0-9a-f]{6,})?$"#)
    static func isServiceName(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return serviceNameRegex.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
    }

    static func corrected(_ detections: [Detection]) -> [Detection] {
        detections.map { reclassify($0) }
    }

    private static func relabel(_ d: Detection, category: SensitiveCategory,
                                label: String, reason: String) -> Detection {
        Detection(category: category, snippet: d.snippet, confidence: d.confidence,
                  rects: d.rects, customLabel: label, reason: reason)
    }

    private static func reclassify(_ d: Detection) -> Detection {
        // Existing: a "money amount" that is actually a measurement.
        if isMoney(d), containsMeasurementUnit(d.snippet) {
            return relabel(d, category: d.category, label: "measurement",
                           reason: "A measurement value, not a monetary amount.")
        }
        // Log timestamp mislabeled as an issue/birth/expiry date.
        if d.category == .contextual, (d.customLabel?.lowercased().contains("date") ?? false),
           isLogTimestamp(d.snippet) {
            return relabel(d, category: .contextual, label: "timestamp",
                           reason: "A log timestamp, not a date of record.")
        }
        // Hostname/path/handle mislabeled as a mailing address (sheds the high-risk category).
        if d.category == .postalAddress, isHostnameOrPath(d.snippet) {
            return relabel(d, category: .contextual, label: "hostname",
                           reason: "A hostname or path, not a postal address.")
        }
        // Internal service name mislabeled as an organization.
        if d.category == .organizationName, isServiceName(d.snippet) {
            return relabel(d, category: .contextual, label: "service name",
                           reason: "An internal service name, not an organization.")
        }
        return d
    }
}
