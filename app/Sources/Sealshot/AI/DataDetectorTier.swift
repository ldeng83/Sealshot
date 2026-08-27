import Foundation

/// All-macOS data extraction via `NSDataDetector` — the fallback for when Vision's
/// macOS-26 document detectors are unavailable or find nothing. Covers dates,
/// addresses, phone numbers, and URLs (email/money come from the Vision/regex/
/// GLiNER tiers). Pure and deterministic.
enum DataDetectorTier {

    static func detect(in text: String) -> (urls: [String], phones: [String], addresses: [String], dates: [String]) {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types:
                NSTextCheckingResult.CheckingType([.link, .phoneNumber, .address, .date]).rawValue)
        else { return ([], [], [], []) }

        var urls: [String] = [], phones: [String] = [], addresses: [String] = [], dates: [String] = []
        let ns = text as NSString
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            switch match.resultType {
            case .link:        if let u = match.url?.absoluteString { urls.append(u) }
            case .phoneNumber: if let p = match.phoneNumber { phones.append(p) }
            case .address:     addresses.append(ns.substring(with: match.range))
            case .date:        dates.append(ns.substring(with: match.range))
            default:           break
            }
        }

        func dedupe(_ a: [String]) -> [String] {
            var seen = Set<String>()
            return a.filter { seen.insert($0).inserted }
        }
        return (dedupe(urls), dedupe(phones), dedupe(addresses), dedupe(dates))
    }
}
