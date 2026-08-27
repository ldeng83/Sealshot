import Foundation

/// Sensitive field labels whose adjacent value should be redacted, grouped by
/// domain and sourced from HIPAA-18, PCI, GDPR special categories, Microsoft
/// Presidio recognizers, and Google Cloud DLP infoTypes. Used to build
/// `ContextualDetectors.labeledValueRegex` (a separator is still required, so a
/// bare label word in prose never matches).
enum SensitiveLabels {
    // Each entry is a regex fragment (already escaped) for one label phrase.
    private static let identity = [
        #"passport(?:\s*(?:number|no\.?|#))?"#, #"national\s*id(?:entity)?(?:\s*(?:number|no\.?|#))?"#,
        #"driver'?s?\s*licen[sc]e(?:\s*(?:number|no\.?|#))?"#, #"licen[sc]e(?:\s*(?:number|no\.?|#))?"#,
        #"visa\s*(?:number|no\.?|#)"#, #"sin"#, #"social\s*insurance(?:\s*number)?"#,
        #"ssn"#, #"social\s*security(?:\s*number)?"#, #"tax\s*id"#, #"tin"#,
        #"dob"#, #"date of birth"#, #"birth\s?date"#, #"d\.o\.b\.?"#, #"place of birth"#,
        #"birthday"#, #"born"#, #"surname"#, #"given\s*names?"#,
        #"nationality"#, #"date of issue"#, #"date of expiry"#, #"issuing authority"#,
        // Synthetic/demo VINs fail the ISO 3779 check digit, so the content
        // rule stays silent on them — the label catches the labeled case.
        #"vin"#, #"vehicle\s*identification(?:\s*(?:number|no\.?))?"#,
    ]
    private static let financial = [
        #"account(?:\s*(?:number|no\.?|#))?"#, #"acct"#, #"iban"#,
        #"routing(?:\s*number)?"#, #"sort\s*code"#, #"card\s*(?:number|no\.?|#)"#,
    ]
    private static let health = [
        #"mrn"#, #"medical\s*record(?:\s*number)?"#, #"patient(?:\s*(?:name|id))?"#,
        #"dx"#, #"icd(?:-?10)?(?:\s*code)?"#, #"cpt(?:\s*code)?"#, #"procedure\s*code"#,
        #"diagnosis"#, #"npi"#, #"health\s*plan(?:\s*number)?"#, #"beneficiary(?:\s*(?:id|number))?"#,
        #"member\s*id"#, #"insurance(?:\s*(?:id|number|member))?"#,
        // Clinical fields (personal medical records / charts): allergy rows,
        // medication/immunization names, biometrics. Values ride the existing
        // label→value machinery (same line, below, or beside).
        #"allerg(?:y|ies)(?:\s*name)?"#, #"reaction"#,
        #"medication(?:\s*name)?"#, #"immunization(?:\s*name)?"#, #"vaccine"#,
        #"blood\s*type"#, #"blood\s*pressure"#, #"heart\s*rate"#, #"pulse"#,
        #"bmi"#, #"body\s*mass\s*index"#, #"height"#, #"weight"#,
    ]
    /// GDPR Article 9 special categories + demographic quasi-identifiers.
    /// Labeled-field detection only — the bare words in prose never match
    /// (the same-line regex needs a separator; the geometry paths need a
    /// label-like line).
    private static let demographics = [
        #"ethnicity"#, #"race"#, #"religious\s*affiliation"#, #"religion"#,
        #"gender"#, #"sex"#, #"sexual\s*orientation"#, #"marital\s*status"#,
        #"relationship"#,
    ]
    private static let employmentLegal = [
        #"employee\s*id"#, #"case\s*(?:number|no\.?|#)"#, #"docket(?:\s*number)?"#,
        #"policy\s*(?:number|no\.?|#)"#, #"claim\s*(?:number|no\.?|#)"#,
        // Ops consoles: internal tickets / incident records carry org context.
        #"(?:internal\s*)?ticket"#, #"incident\s*(?:record|link|id|number)"#,
        // E-signature consoles: envelope/document IDs often gate access links.
        #"envelope\s*id"#, #"document\s*id"#,
        // Claims/invoicing document identifiers.
        #"invoice\s*(?:number|no\.?|#)"#, #"work\s*order\s*(?:number|no\.?|#)?"#,
        #"estimate\s*ref(?:erence)?\s*(?:number|no\.?|#)?"#,
        #"police\s*report\s*(?:number|no\.?|#)?"#, #"odometer"#, #"mileage"#,
        #"(?:license\s*)?plate\s*(?:number|no\.?|#)?"#,
    ]
    /// Name-family labels: the value is a person name the NER should catch but
    /// statistically misses on isolated form cells ("Jasen Gaylord" beside
    /// "Full Name:"). Deliberately multi-word (no bare "name" — a Finder
    /// "Name" column would box every filename).
    private static let names = [
        #"full\s*name"#, #"first\s*name"#, #"last\s*name"#, #"middle\s*name"#,
        #"customer\s*name"#, #"account\s*holder(?:\s*name)?"#,
        #"contact(?:\s*(?:name|number|no\.?))?"#, #"emergency\s*contact"#, #"guardian"#,
        // Role labels whose value is the subject's name (claims, leases,
        // real-estate and school records).
        #"claimant"#, #"tenant"#, #"landlord"#, #"buyer"#, #"seller"#,
        #"borrower"#, #"applicant"#, #"insured"#, #"adjuster"#,
        #"student(?:\s*(?:name|id))?"#, #"prepared\s*for"#,
    ]
    /// Travel identifiers: a booking reference/PNR identifies a person's full
    /// itinerary (and often unlocks it on airline sites).
    private static let travel = [
        #"booking\s*(?:reference|ref\.?|number|no\.?|#)"#,
        #"confirmation\s*(?:number|no\.?|code|#)"#,
        #"reservation\s*(?:number|no\.?|code|#)"#,
        #"pnr"#, #"record\s*locator"#,
        #"tracking\s*(?:number|no\.?|#)"#, #"tracking\s*/\s*barcode"#, #"barcodes?"#,
    ]
    /// Secret-material field labels (ops consoles, secret managers, login
    /// forms): the value beside/below is credential material. Masked values
    /// ("••••••") fail the value gates and are skipped.
    private static let secrets = [
        #"credentials?"#, #"api\s*key"#, #"secret(?:\s*(?:value|key))?"#,
        #"passwords?"#, #"access\s*token"#, #"client\s*secret"#, #"token"#,
        // Codes-family: 2FA backup/recovery code GRIDS (handled by the code-
        // grid collector in the analyzer, not the single-value paths).
        #"(?:backup|recovery|scratch|one[\-\s]?time)\s*(?:verification\s*)?(?:pass)?codes?"#,
        #"verification\s*codes?"#, #"otp"#,
        // Meeting credentials (join info grants access).
        #"meeting\s*id"#, #"passcode"#,
    ]
    /// Structured-format field names: the labels above are written for prose
    /// ("Tax ID:", "Medical Record Number:"), but the same fields appear in
    /// JSON/YAML/env dumps as `tax_id`, `medical_record_number`, `TAX-ID`.
    /// Rather than duplicating every fragment, relax each fragment's internal
    /// whitespace to ALSO accept `_` and `-`, so one entry covers both worlds.
    private static func allowingWordSeparators(_ fragment: String) -> String {
        fragment
            .replacingOccurrences(of: #"\s*"#, with: #"[\s_\-]*"#)
            .replacingOccurrences(of: #"\s+"#, with: #"[\s_\-]+"#)
            .replacingOccurrences(of: " ", with: #"[\s_\-]"#)
    }

    /// Fields that show up almost exclusively as structured keys — config
    /// dumps, API responses, `.env` files, secret managers. Kept apart from
    /// the prose vocabularies above because several are only safe WITH a
    /// separator and a value beside them: a bare "pin" or "state" in prose is
    /// an ordinary word, but `"pin": "482913"` never is.
    private static let structuredOnly = [
        // Authentication secondaries — the fields that unlock an account when
        // the password alone doesn't.
        #"pin(?:\s*code)?"#, #"cvv2?"#, #"cvc2?"#, #"csc"#,
        #"security\s*(?:answer|question)"#, #"secret\s*(?:answer|question)"#,
        #"mother'?s?\s*maiden\s*name"#,
        // Credential material beyond the `secrets` list above.
        #"(?:refresh|session|auth|bearer|id)\s*token"#, #"session\s*id"#,
        #"authorization"#, #"client\s*id"#, #"app\s*secret"#,
        #"private\s*key"#, #"encryption\s*key"#, #"signing\s*key"#,
        #"webhook\s*secret"#, #"storage\s*key"#, #"service\s*account"#,
        #"connection\s*string"#, #"database\s*url"#, #"conn\s*str"#,
        // Connection URIs carry the credentials inline.
        #"(?:mongodb|postgres(?:ql)?|mysql|redis|amqp|db|database|connection)\s*uri"#,
        #"datasource(?:\s*url)?"#, #"dsn"#,
        #"recovery\s*code"#, #"backup\s*code"#,
        // Account identity. Safe only in this structured form: a "Username"
        // column header in a UI has no `: value` beside it, and the geometry
        // paths (which would box such a column) deliberately don't get these.
        #"user\s*name"#, #"login(?:\s*(?:id|name))?"#, #"user\s*id"#,
        // ZIP/postal is one of the HIPAA-18 identifiers.
        #"postal\s*code"#, #"zip(?:\s*code)?"#, #"post\s*code"#,
        // Financial fields the prose list words differently.
        #"swift(?:\s*(?:bic|code))?"#, #"bic"#,
        #"cardholder(?:\s*name)?"#, #"expiration\s*date"#, #"exp\s*date"#,
        #"billing\s*postal\s*code"#,
        // Network identity — an internal hostname or VPN account is a way in.
        #"vpn\s*(?:username|user|password|pass)"#, #"hostname"#, #"host\s*name"#,
        #"mac\s*address"#, #"private\s*ip(?:v4|v6)?"#, #"public\s*ip(?:v4|v6)?"#,
        // The address itself is matched by content too, but OCR mangles long
        // colon runs, so the label is the reliable path for IPv6.
        #"ipv6"#, #"ipv4"#, #"ip\s*address"#,
    ]

    /// All label fragments OR-joined for the labeled-value regex.
    static let valueLabelAlternation: String =
        (identity + financial + health + demographics + employmentLegal + travel + names
            + secrets + structuredOnly)
            .map(allowingWordSeparators)
            .joined(separator: "|")

    /// Fragments for the GEOMETRY paths (label-above/beside detection), where
    /// a bare "account" is too promiscuous — it anchors on ordinary UI text
    /// and drags in neighbouring key columns. The same-line regex keeps the
    /// bare form (a separator bounds it there).
    private static let financialGeometry = [
        #"account\s*(?:number|no\.?|#|id)"#, #"acct\.?\s*(?:number|no\.?|#|id)"#, #"iban"#,
        #"routing(?:\s*number)?"#, #"sort\s*code"#, #"card\s*(?:number|no\.?|#)"#,
    ]
    static let geometryLabelAlternation: String =
        (identity + financialGeometry + health + demographics + employmentLegal + travel + names + secrets)
            .joined(separator: "|")
}
