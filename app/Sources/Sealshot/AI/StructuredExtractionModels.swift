import Foundation

/// Plain, OS-agnostic value types for extracted structured data. The
/// macOS-26 @Generable schema maps INTO these at the engine boundary, so all
/// formatting logic stays testable on any OS.
struct StructuredTable: Equatable, Codable { let headers: [String]; let rows: [[String]] }
struct StructuredContact: Equatable, Codable {
    let name: String; let email: String; let phone: String
    let organization: String; let title: String
}
struct StructuredCode: Equatable, Codable { let language: String; let code: String }
struct StructuredField: Equatable, Codable { let label: String; let value: String }

struct StructuredItems: Equatable, Codable {
    var tables: [StructuredTable] = []
    var contacts: [StructuredContact] = []
    var codeBlocks: [StructuredCode] = []
    var formFields: [StructuredField] = []
    var urls: [String] = []
    var emails: [String] = []
    var phones: [String] = []
    var addresses: [String] = []
    var money: [String] = []
    var dates: [String] = []
    var stackTraces: [String] = []
}
