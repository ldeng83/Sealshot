import CoreGraphics
import DataDetection
import Vision

// MARK: - DocumentData

struct DocumentData: Equatable {
    var urls: [String] = []
    var dates: [String] = []
    var emails: [String] = []
    var phones: [String] = []
    var addresses: [String] = []
    var money: [String] = []
    var nativeTables: [StructuredTable] = []
}

// MARK: - DocumentDataExtractor

@available(macOS 26, *)
struct DocumentDataExtractor {
    /// Runs Vision's `RecognizeDocumentsRequest` over the given image and extracts
    /// typed detected-data lists plus any native tables Vision found.
    func extract(_ image: CGImage) async throws -> DocumentData {
        let request = RecognizeDocumentsRequest()
        let observations: [DocumentObservation] = try await request.perform(on: image, orientation: nil)

        var result = DocumentData()

        for obs in observations {
            let doc = obs.document

            // MARK: Detected data
            let transcript = doc.text.transcript
            for ddMatch in doc.text.detectedData {
                let match = ddMatch.match
                // Extract the matched substring from the transcript when range is available;
                // fall back to detail-specific string construction.
                let rawText: String = {
                    if let range = match.range, !transcript.isEmpty, range.lowerBound <= transcript.endIndex, range.upperBound <= transcript.endIndex {
                        return String(transcript[range])
                    }
                    return ""
                }()

                switch match.details {
                case .link(let link):
                    result.urls.append(link.url.absoluteString)

                case .emailAddress(let email):
                    result.emails.append(email.emailAddress)

                case .phoneNumber(let phone):
                    result.phones.append(phone.phoneNumber)

                case .postalAddress(let address):
                    let formatted = address.fullAddress.isEmpty ? rawText : address.fullAddress
                    if !formatted.isEmpty {
                        result.addresses.append(formatted)
                    } else if !rawText.isEmpty {
                        result.addresses.append(rawText)
                    }

                case .calendarEvent(let event):
                    // Prefer the matched transcript text; fall back to ISO date if available.
                    if !rawText.isEmpty {
                        result.dates.append(rawText)
                    } else if let date = event.startDate {
                        result.dates.append(ISO8601DateFormatter().string(from: date))
                    }

                case .moneyAmount(let money):
                    if !rawText.isEmpty {
                        result.money.append(rawText)
                    } else {
                        result.money.append("\(money.currency.identifier) \(money.amount)")
                    }

                default:
                    // flightNumber, shipmentTrackingNumber, measurement, paymentIdentifier — ignore
                    break
                }
            }

            // MARK: Native tables
            for table in doc.tables {
                let allRows = table.rows
                // Skip degenerate tables: need at least 2 rows and 2 columns.
                guard allRows.count >= 2, allRows.first.map({ $0.count >= 2 }) == true else { continue }

                let headers: [String] = allRows[0].map { cell in
                    cell.content.text.transcript
                }
                let rows: [[String]] = allRows.dropFirst().map { row in
                    row.map { cell in cell.content.text.transcript }
                }

                result.nativeTables.append(StructuredTable(headers: headers, rows: rows))
            }
        }

        return result
    }
}
