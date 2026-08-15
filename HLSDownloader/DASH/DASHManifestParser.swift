import Foundation

enum DASHPresentationType: String, Equatable, Sendable {
    case staticPresentation = "static"
    case dynamic = "dynamic"
    case unknown
}

enum DASHMediaType: String, Equatable, Sendable {
    case audio
    case video
    case text
    case unknown
}

enum DASHCommonEncryptionScheme: String, Hashable, Sendable {
    case cenc
    case cbcs
}

struct DASHPSSHBox: Equatable, Sendable {
    let rawData: Data
    let version: UInt8
    let flags: UInt32
    let systemID: String
    let keyIDs: [String]
    let data: Data
}

struct DASHContentProtection: Equatable, Sendable {
    let schemeIDURI: String?
    let value: String?
    let defaultKeyIDs: [String]
    let psshBoxes: [DASHPSSHBox]
    let licenseURLs: [URL]
    let containsMalformedPSSH: Bool

    var isWidevine: Bool {
        let widevineURN = "urn:uuid:\(DASHManifestParser.widevineSystemID)"
        if schemeIDURI?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == widevineURN {
            return true
        }
        return psshBoxes.contains {
            $0.systemID.caseInsensitiveCompare(DASHManifestParser.widevineSystemID) == .orderedSame
        }
    }

    var commonEncryptionScheme: DASHCommonEncryptionScheme? {
        guard schemeIDURI?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == DASHManifestParser.mp4ProtectionScheme else {
            return nil
        }
        let fourCC = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", maxSplits: 1)
            .first?
            .lowercased()
        return fourCC.flatMap { DASHCommonEncryptionScheme(rawValue: $0) }
    }
}

struct DASHBaseURL: Equatable, Sendable {
    let rawValue: String
    let resolvedURL: URL?
}

struct DASHSegmentTimelineEntry: Equatable, Sendable {
    let startTime: Int64?
    let duration: UInt64?
    let repeatCount: Int64?
}

struct DASHSegmentTemplate: Equatable, Sendable {
    let initialization: String?
    let media: String?
    let index: String?
    let timescale: UInt64?
    let duration: UInt64?
    let startNumber: UInt64?
    let presentationTimeOffset: UInt64?
    let endNumber: UInt64?
    let timeline: [DASHSegmentTimelineEntry]
}

struct DASHSegmentURL: Equatable, Sendable {
    let media: String?
    let mediaRange: String?
    let index: String?
    let indexRange: String?
}

struct DASHSegmentList: Equatable, Sendable {
    let timescale: UInt64?
    let duration: UInt64?
    let startNumber: UInt64?
    let presentationTimeOffset: UInt64?
    let initializationSourceURL: String?
    let initializationRange: String?
    let segmentURLs: [DASHSegmentURL]
}

struct DASHRepresentation: Equatable, Sendable {
    let id: String?
    let bandwidth: UInt64?
    let mimeType: String?
    let codecs: String?
    let width: UInt64?
    let height: UInt64?
    let mediaType: DASHMediaType
    let baseURLs: [DASHBaseURL]
    let segmentTemplate: DASHSegmentTemplate?
    let segmentList: DASHSegmentList?
    let contentProtections: [DASHContentProtection]
}

struct DASHAdaptationSet: Equatable, Sendable {
    let id: String?
    let contentType: String?
    let mimeType: String?
    let language: String?
    let mediaType: DASHMediaType
    let baseURLs: [DASHBaseURL]
    let segmentTemplate: DASHSegmentTemplate?
    let segmentList: DASHSegmentList?
    let contentProtections: [DASHContentProtection]
    let representations: [DASHRepresentation]
}

struct DASHPeriod: Equatable, Sendable {
    let id: String?
    let start: String?
    let duration: String?
    let baseURLs: [DASHBaseURL]
    let segmentTemplate: DASHSegmentTemplate?
    let segmentList: DASHSegmentList?
    let contentProtections: [DASHContentProtection]
    let adaptationSets: [DASHAdaptationSet]
}

struct DASHManifest: Equatable, Sendable {
    let effectiveURL: URL
    let presentationType: DASHPresentationType
    let mediaPresentationDuration: String?
    let minimumUpdatePeriod: String?
    let baseURLs: [DASHBaseURL]
    let segmentTemplate: DASHSegmentTemplate?
    let segmentList: DASHSegmentList?
    let contentProtections: [DASHContentProtection]
    let periods: [DASHPeriod]

    var adaptationSets: [DASHAdaptationSet] {
        periods.flatMap(\.adaptationSets)
    }

    var allContentProtections: [DASHContentProtection] {
        contentProtections + periods.flatMap { period in
            period.contentProtections + period.adaptationSets.flatMap { adaptation in
                adaptation.contentProtections
                    + adaptation.representations.flatMap(\.contentProtections)
            }
        }
    }

    var isWidevine: Bool {
        allContentProtections.contains(where: \.isWidevine)
    }

    var encryptionSchemes: Set<DASHCommonEncryptionScheme> {
        Set(allContentProtections.compactMap(\.commonEncryptionScheme))
    }

    var psshBoxes: [DASHPSSHBox] {
        allContentProtections.flatMap(\.psshBoxes)
    }

    var licenseURLs: [URL] {
        var seen = Set<String>()
        return allContentProtections
            .flatMap(\.licenseURLs)
            .filter { seen.insert($0.absoluteString).inserted }
    }

    var widevineLicenseURLs: [URL] {
        var seen = Set<String>()
        return allContentProtections
            .filter(\.isWidevine)
            .flatMap(\.licenseURLs)
            .filter { seen.insert($0.absoluteString).inserted }
    }
}

enum DASHManifestParserError: LocalizedError, Sendable {
    case manifestTooLarge
    case notMPD
    case invalidXML(String)
    case complexityLimitExceeded

    var errorDescription: String? {
        switch self {
        case .manifestTooLarge:
            return "MPDが大きすぎます。"
        case .notMPD:
            return "XMLのルート要素がMPDではありません。"
        case .invalidXML(let detail):
            return "MPDを解析できません: \(detail)"
        case .complexityLimitExceeded:
            return "MPDの要素数が安全上限を超えました。"
        }
    }
}

enum DASHManifestParser {
    static let namespace = "urn:mpeg:dash:schema:mpd:2011"
    static let widevineSystemID = "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
    static let mp4ProtectionScheme = "urn:mpeg:dash:mp4protection:2011"

    private static let maximumManifestBytes = 4 * 1_024 * 1_024

    static func isMPD(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumManifestBytes else { return false }
        let detector = MPDRootDetector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = detector
        _ = parser.parse()
        return detector.isMPD
    }

    static func isMPD(_ text: String) -> Bool {
        isMPD(Data(text.utf8))
    }

    static func parse(data: Data, effectiveURL: URL) throws -> DASHManifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw DASHManifestParserError.manifestTooLarge
        }

        let builder = DASHXMLBuilder(effectiveURL: effectiveURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let parsed = parser.parse()

        if let failure = builder.failure { throw failure }
        guard parsed else {
            throw DASHManifestParserError.invalidXML(
                parser.parserError?.localizedDescription ?? "不正なXMLです"
            )
        }
        return try builder.makeManifest()
    }

    static func parse(text: String, effectiveURL: URL) throws -> DASHManifest {
        try parse(data: Data(text.utf8), effectiveURL: effectiveURL)
    }
}

private final class MPDRootDetector: NSObject, XMLParserDelegate {
    private(set) var isMPD = false
    private var sawRoot = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard !sawRoot else { return }
        sawRoot = true
        isMPD = isMPDRoot(
            xmlLocalName(elementName, qualifiedName: qName),
            namespaceURI: namespaceURI
        )
        parser.abortParsing()
    }
}

private final class DASHXMLBuilder: NSObject, XMLParserDelegate {
    private static let maximumElements = 100_000
    private static let maximumAttributesPerElement = 64
    private static let maximumAttributeLength = 8_192
    private static let maximumTextBytes = 8 * 1_024 * 1_024
    private static let maximumRepresentations = 4_096
    private static let maximumProtections = 4_096
    private static let maximumSegmentURLs = 200_000
    private static let maximumPSSHCharacters = 512 * 1_024

    private enum TextCaptureKind: Equatable {
        case baseURL
        case pssh
        case licenseURL
    }

    private struct TextCapture {
        let kind: TextCaptureKind
        let elementName: String
        let depth: Int
        var value: String
    }

    private let effectiveURL: URL
    private var elementCount = 0
    private var textByteCount = 0
    private var depth = 0
    private var rootElement: String?
    private var capture: TextCapture?

    private var presentationType = DASHPresentationType.unknown
    private var mediaPresentationDuration: String?
    private var minimumUpdatePeriod: String?
    private var baseURLs: [DASHBaseURL] = []
    private var manifestSegmentTemplate: DASHSegmentTemplate?
    private var manifestSegmentList: DASHSegmentList?
    private var manifestProtections: [DASHContentProtection] = []
    private var periods: [DASHPeriod] = []

    private var period: DASHPeriodBuilder?
    private var adaptation: DASHAdaptationBuilder?
    private var representation: DASHRepresentationBuilder?
    private var protection: DASHProtectionBuilder?
    private var segmentTemplate: DASHSegmentTemplateBuilder?
    private var segmentList: DASHSegmentListBuilder?

    private(set) var failure: DASHManifestParserError?

    init(effectiveURL: URL) {
        self.effectiveURL = effectiveURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        depth += 1
        elementCount += 1
        guard elementCount <= Self.maximumElements,
              attributeDict.count <= Self.maximumAttributesPerElement,
              attributeDict.allSatisfy({
                  $0.key.utf8.count <= Self.maximumAttributeLength
                      && $0.value.utf8.count <= Self.maximumAttributeLength
              }) else {
            fail(parser, with: .complexityLimitExceeded)
            return
        }

        let name = xmlLocalName(elementName, qualifiedName: qName)
        if rootElement == nil {
            rootElement = name
            guard isMPDRoot(name, namespaceURI: namespaceURI) else {
                fail(parser, with: .notMPD)
                return
            }
        }

        switch name {
        case "MPD":
            switch attribute("type", in: attributeDict)?.lowercased() {
            case "static": presentationType = .staticPresentation
            case "dynamic": presentationType = .dynamic
            default: presentationType = .unknown
            }
            mediaPresentationDuration = attribute("mediaPresentationDuration", in: attributeDict)
            minimumUpdatePeriod = attribute("minimumUpdatePeriod", in: attributeDict)

        case "Period":
            period = DASHPeriodBuilder(
                id: attribute("id", in: attributeDict),
                start: attribute("start", in: attributeDict),
                duration: attribute("duration", in: attributeDict)
            )

        case "AdaptationSet":
            adaptation = DASHAdaptationBuilder(
                id: attribute("id", in: attributeDict),
                contentType: attribute("contentType", in: attributeDict),
                mimeType: attribute("mimeType", in: attributeDict),
                language: attribute("lang", in: attributeDict)
            )

        case "Representation":
            representation = DASHRepresentationBuilder(
                id: attribute("id", in: attributeDict),
                bandwidth: unsignedAttribute("bandwidth", in: attributeDict),
                mimeType: attribute("mimeType", in: attributeDict),
                codecs: attribute("codecs", in: attributeDict),
                width: unsignedAttribute("width", in: attributeDict),
                height: unsignedAttribute("height", in: attributeDict)
            )

        case "ContentProtection":
            guard totalProtectionCount < Self.maximumProtections else {
                fail(parser, with: .complexityLimitExceeded)
                return
            }
            let builder = DASHProtectionBuilder(
                schemeIDURI: attribute("schemeIdUri", in: attributeDict),
                value: attribute("value", in: attributeDict),
                defaultKeyIDs: parseUUIDList(attribute("default_KID", in: attributeDict))
            )
            appendLicenseURLAttributes(attributeDict, to: builder)
            protection = builder

        case "BaseURL":
            beginCapture(.baseURL, name: name)

        case "SegmentTemplate":
            segmentTemplate = DASHSegmentTemplateBuilder(attributes: attributeDict)

        case "S":
            segmentTemplate?.timeline.append(
                DASHSegmentTimelineEntry(
                    startTime: signedAttribute("t", in: attributeDict),
                    duration: unsignedAttribute("d", in: attributeDict),
                    repeatCount: signedAttribute("r", in: attributeDict)
                )
            )

        case "SegmentList":
            segmentList = DASHSegmentListBuilder(attributes: attributeDict)

        case "Initialization":
            if let segmentList {
                segmentList.initializationSourceURL = attribute("sourceURL", in: attributeDict)
                segmentList.initializationRange = attribute("range", in: attributeDict)
            }

        case "SegmentURL":
            guard let segmentList else { break }
            guard segmentList.segmentURLs.count < Self.maximumSegmentURLs else {
                fail(parser, with: .complexityLimitExceeded)
                return
            }
            segmentList.segmentURLs.append(
                DASHSegmentURL(
                    media: attribute("media", in: attributeDict),
                    mediaRange: attribute("mediaRange", in: attributeDict),
                    index: attribute("index", in: attributeDict),
                    indexRange: attribute("indexRange", in: attributeDict)
                )
            )

        case "pssh":
            if protection != nil { beginCapture(.pssh, name: name) }

        case "Laurl", "laurl", "LicenseURL", "licenseUrl", "licenseURL":
            if let protection {
                appendLicenseURLAttributes(attributeDict, to: protection)
                beginCapture(.licenseURL, name: name)
            }

        default:
            if let protection,
               name.lowercased().contains("license") || name.lowercased().contains("laurl") {
                appendLicenseURLAttributes(attributeDict, to: protection)
                beginCapture(.licenseURL, name: name)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendCapturedText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            fail(parser, with: .invalidXML("CDATAをUTF-8として読み取れません"))
            return
        }
        appendCapturedText(text, parser: parser)
    }

    private func appendCapturedText(_ string: String, parser: XMLParser) {
        guard failure == nil else { return }
        let byteCount = string.utf8.count
        guard byteCount <= Self.maximumTextBytes - textByteCount else {
            fail(parser, with: .complexityLimitExceeded)
            return
        }
        textByteCount += byteCount
        guard var capture else { return }
        let maximum = capture.kind == .pssh ? Self.maximumPSSHCharacters : Self.maximumAttributeLength
        let capturedByteCount = capture.value.utf8.count
        guard capturedByteCount <= maximum,
              byteCount <= maximum - capturedByteCount else {
            fail(parser, with: .complexityLimitExceeded)
            return
        }
        capture.value += string
        self.capture = capture
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        let name = xmlLocalName(elementName, qualifiedName: qName)

        if let capture, capture.depth == depth, capture.elementName == name {
            finishCapture(capture)
            self.capture = nil
        }

        switch name {
        case "ContentProtection":
            if let protection {
                append(protection.makeModel())
                self.protection = nil
            }

        case "SegmentTemplate":
            if let segmentTemplate {
                assign(segmentTemplate.makeModel())
                self.segmentTemplate = nil
            }

        case "SegmentList":
            if let segmentList {
                assign(segmentList.makeModel())
                self.segmentList = nil
            }

        case "Representation":
            if let representation {
                guard totalRepresentationCount < Self.maximumRepresentations else {
                    fail(parser, with: .complexityLimitExceeded)
                    return
                }
                adaptation?.representations.append(
                    representation.makeModel(inheritedMediaType: adaptation?.mediaType ?? .unknown)
                )
                self.representation = nil
            }

        case "AdaptationSet":
            if let adaptation {
                period?.adaptationSets.append(adaptation.makeModel())
                self.adaptation = nil
            }

        case "Period":
            if let period {
                periods.append(period.makeModel())
                self.period = nil
            }

        default:
            break
        }
        depth -= 1
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(parser, with: .invalidXML("外部entityは使用できません"))
        return nil
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(parser, with: .invalidXML("外部entity宣言は使用できません"))
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(parser, with: .invalidXML("内部entity宣言は使用できません"))
    }

    func makeManifest() throws -> DASHManifest {
        guard rootElement == "MPD" else { throw DASHManifestParserError.notMPD }
        return DASHManifest(
            effectiveURL: effectiveURL,
            presentationType: presentationType,
            mediaPresentationDuration: mediaPresentationDuration,
            minimumUpdatePeriod: minimumUpdatePeriod,
            baseURLs: baseURLs,
            segmentTemplate: manifestSegmentTemplate,
            segmentList: manifestSegmentList,
            contentProtections: manifestProtections,
            periods: periods
        )
    }

    private var totalRepresentationCount: Int {
        periods.reduce(0) { count, period in
            count + period.adaptationSets.reduce(0) { $0 + $1.representations.count }
        } + (period?.adaptationSets.reduce(0) { $0 + $1.representations.count } ?? 0)
            + (adaptation?.representations.count ?? 0)
    }

    private var totalProtectionCount: Int {
        let completed = manifestProtections.count + periods.reduce(0) { count, period in
            count + period.contentProtections.count
                + period.adaptationSets.reduce(0) { subtotal, adaptation in
                    subtotal + adaptation.contentProtections.count
                        + adaptation.representations.reduce(0) { $0 + $1.contentProtections.count }
                }
        }
        return completed
            + (period?.contentProtections.count ?? 0)
            + (adaptation?.contentProtections.count ?? 0)
            + (representation?.contentProtections.count ?? 0)
    }

    private func beginCapture(_ kind: TextCaptureKind, name: String) {
        guard capture == nil else { return }
        capture = TextCapture(kind: kind, elementName: name, depth: depth, value: "")
    }

    private func finishCapture(_ capture: TextCapture) {
        let value = capture.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch capture.kind {
        case .baseURL:
            append(makeBaseURL(value))
        case .pssh:
            guard let protection else { return }
            let compact = value.filter { !$0.isWhitespace }
            guard let bytes = Data(base64Encoded: compact),
                  let boxes = DASHPSSHParser.parse(bytes) else {
                protection.containsMalformedPSSH = true
                return
            }
            protection.psshBoxes.append(contentsOf: boxes)
        case .licenseURL:
            if let url = safeWebURL(value) { protection?.appendLicenseURL(url) }
        }
    }

    private func append(_ baseURL: DASHBaseURL) {
        if let representation { representation.baseURLs.append(baseURL) }
        else if let adaptation { adaptation.baseURLs.append(baseURL) }
        else if let period { period.baseURLs.append(baseURL) }
        else { baseURLs.append(baseURL) }
    }

    private func append(_ protection: DASHContentProtection) {
        if let representation { representation.contentProtections.append(protection) }
        else if let adaptation { adaptation.contentProtections.append(protection) }
        else if let period { period.contentProtections.append(protection) }
        else { manifestProtections.append(protection) }
    }

    private func assign(_ template: DASHSegmentTemplate) {
        if let representation { representation.segmentTemplate = template }
        else if let adaptation { adaptation.segmentTemplate = template }
        else if let period { period.segmentTemplate = template }
        else { manifestSegmentTemplate = template }
    }

    private func assign(_ list: DASHSegmentList) {
        if let representation { representation.segmentList = list }
        else if let adaptation { adaptation.segmentList = list }
        else if let period { period.segmentList = list }
        else { manifestSegmentList = list }
    }

    private func makeBaseURL(_ value: String) -> DASHBaseURL {
        DASHBaseURL(
            rawValue: value,
            resolvedURL: safeWebURL(value, relativeTo: inheritedBaseURLForCurrentScope)
        )
    }

    private var inheritedBaseURLForCurrentScope: URL {
        if representation != nil {
            return adaptation?.baseURLs.first?.resolvedURL
                ?? period?.baseURLs.first?.resolvedURL
                ?? baseURLs.first?.resolvedURL
                ?? effectiveURL
        }
        if adaptation != nil {
            return period?.baseURLs.first?.resolvedURL
                ?? baseURLs.first?.resolvedURL
                ?? effectiveURL
        }
        if period != nil {
            return baseURLs.first?.resolvedURL ?? effectiveURL
        }
        return effectiveURL
    }

    private func appendLicenseURLAttributes(
        _ attributes: [String: String],
        to protection: DASHProtectionBuilder
    ) {
        for name in ["licenseUrl", "licenseURL", "laurl", "href"] {
            if let value = attribute(name, in: attributes), let url = safeWebURL(value) {
                protection.appendLicenseURL(url)
            }
        }
    }

    private func safeWebURL(_ rawValue: String, relativeTo baseURL: URL? = nil) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolutionBaseURL = baseURL ?? effectiveURL
        guard !value.isEmpty,
              value.utf8.count <= Self.maximumAttributeLength,
              let url = URL(string: value, relativeTo: resolutionBaseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }

    private func fail(_ parser: XMLParser, with error: DASHManifestParserError) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

private final class DASHProtectionBuilder {
    let schemeIDURI: String?
    let value: String?
    let defaultKeyIDs: [String]
    var psshBoxes: [DASHPSSHBox] = []
    var licenseURLs: [URL] = []
    var containsMalformedPSSH = false

    init(schemeIDURI: String?, value: String?, defaultKeyIDs: [String]) {
        self.schemeIDURI = schemeIDURI
        self.value = value
        self.defaultKeyIDs = defaultKeyIDs
    }

    func appendLicenseURL(_ url: URL) {
        guard !licenseURLs.contains(url) else { return }
        licenseURLs.append(url)
    }

    func makeModel() -> DASHContentProtection {
        DASHContentProtection(
            schemeIDURI: schemeIDURI,
            value: value,
            defaultKeyIDs: defaultKeyIDs,
            psshBoxes: psshBoxes,
            licenseURLs: licenseURLs,
            containsMalformedPSSH: containsMalformedPSSH
        )
    }
}

private final class DASHRepresentationBuilder {
    let id: String?
    let bandwidth: UInt64?
    let mimeType: String?
    let codecs: String?
    let width: UInt64?
    let height: UInt64?
    var baseURLs: [DASHBaseURL] = []
    var segmentTemplate: DASHSegmentTemplate?
    var segmentList: DASHSegmentList?
    var contentProtections: [DASHContentProtection] = []

    init(id: String?, bandwidth: UInt64?, mimeType: String?, codecs: String?, width: UInt64?, height: UInt64?) {
        self.id = id
        self.bandwidth = bandwidth
        self.mimeType = mimeType
        self.codecs = codecs
        self.width = width
        self.height = height
    }

    func makeModel(inheritedMediaType: DASHMediaType) -> DASHRepresentation {
        let ownType = inferMediaType(contentType: nil, mimeType: mimeType, codecs: codecs)
        return DASHRepresentation(
            id: id,
            bandwidth: bandwidth,
            mimeType: mimeType,
            codecs: codecs,
            width: width,
            height: height,
            mediaType: ownType == .unknown ? inheritedMediaType : ownType,
            baseURLs: baseURLs,
            segmentTemplate: segmentTemplate,
            segmentList: segmentList,
            contentProtections: contentProtections
        )
    }
}

private final class DASHAdaptationBuilder {
    let id: String?
    let contentType: String?
    let mimeType: String?
    let language: String?
    let mediaType: DASHMediaType
    var baseURLs: [DASHBaseURL] = []
    var segmentTemplate: DASHSegmentTemplate?
    var segmentList: DASHSegmentList?
    var contentProtections: [DASHContentProtection] = []
    var representations: [DASHRepresentation] = []

    init(id: String?, contentType: String?, mimeType: String?, language: String?) {
        self.id = id
        self.contentType = contentType
        self.mimeType = mimeType
        self.language = language
        mediaType = inferMediaType(contentType: contentType, mimeType: mimeType, codecs: nil)
    }

    func makeModel() -> DASHAdaptationSet {
        let resolvedMediaType = mediaType == .unknown
            ? representations.first(where: { $0.mediaType != .unknown })?.mediaType ?? .unknown
            : mediaType
        return DASHAdaptationSet(
            id: id,
            contentType: contentType,
            mimeType: mimeType,
            language: language,
            mediaType: resolvedMediaType,
            baseURLs: baseURLs,
            segmentTemplate: segmentTemplate,
            segmentList: segmentList,
            contentProtections: contentProtections,
            representations: representations
        )
    }
}

private final class DASHPeriodBuilder {
    let id: String?
    let start: String?
    let duration: String?
    var baseURLs: [DASHBaseURL] = []
    var segmentTemplate: DASHSegmentTemplate?
    var segmentList: DASHSegmentList?
    var contentProtections: [DASHContentProtection] = []
    var adaptationSets: [DASHAdaptationSet] = []

    init(id: String?, start: String?, duration: String?) {
        self.id = id
        self.start = start
        self.duration = duration
    }

    func makeModel() -> DASHPeriod {
        DASHPeriod(
            id: id,
            start: start,
            duration: duration,
            baseURLs: baseURLs,
            segmentTemplate: segmentTemplate,
            segmentList: segmentList,
            contentProtections: contentProtections,
            adaptationSets: adaptationSets
        )
    }
}

private final class DASHSegmentTemplateBuilder {
    let initialization: String?
    let media: String?
    let index: String?
    let timescale: UInt64?
    let duration: UInt64?
    let startNumber: UInt64?
    let presentationTimeOffset: UInt64?
    let endNumber: UInt64?
    var timeline: [DASHSegmentTimelineEntry] = []

    init(attributes: [String: String]) {
        initialization = attribute("initialization", in: attributes)
        media = attribute("media", in: attributes)
        index = attribute("index", in: attributes)
        timescale = unsignedAttribute("timescale", in: attributes)
        duration = unsignedAttribute("duration", in: attributes)
        startNumber = unsignedAttribute("startNumber", in: attributes)
        presentationTimeOffset = unsignedAttribute("presentationTimeOffset", in: attributes)
        endNumber = unsignedAttribute("endNumber", in: attributes)
    }

    func makeModel() -> DASHSegmentTemplate {
        DASHSegmentTemplate(
            initialization: initialization,
            media: media,
            index: index,
            timescale: timescale,
            duration: duration,
            startNumber: startNumber,
            presentationTimeOffset: presentationTimeOffset,
            endNumber: endNumber,
            timeline: timeline
        )
    }
}

private final class DASHSegmentListBuilder {
    let timescale: UInt64?
    let duration: UInt64?
    let startNumber: UInt64?
    let presentationTimeOffset: UInt64?
    var initializationSourceURL: String?
    var initializationRange: String?
    var segmentURLs: [DASHSegmentURL] = []

    init(attributes: [String: String]) {
        timescale = unsignedAttribute("timescale", in: attributes)
        duration = unsignedAttribute("duration", in: attributes)
        startNumber = unsignedAttribute("startNumber", in: attributes)
        presentationTimeOffset = unsignedAttribute("presentationTimeOffset", in: attributes)
    }

    func makeModel() -> DASHSegmentList {
        DASHSegmentList(
            timescale: timescale,
            duration: duration,
            startNumber: startNumber,
            presentationTimeOffset: presentationTimeOffset,
            initializationSourceURL: initializationSourceURL,
            initializationRange: initializationRange,
            segmentURLs: segmentURLs
        )
    }
}

private enum DASHPSSHParser {
    private static let maximumBytes = 384 * 1_024
    private static let maximumBoxes = 32
    private static let maximumKeyIDs = 4_096

    static func parse(_ data: Data) -> [DASHPSSHBox]? {
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        var boxes: [DASHPSSHBox] = []
        var offset = 0

        while offset < data.count {
            guard boxes.count < maximumBoxes,
                  let size32 = readUInt32(data, at: offset),
                  let type = ascii(data, at: offset + 4, length: 4) else { return nil }
            var headerSize = 8
            let boxSize: UInt64
            if size32 == 1 {
                guard let extended = readUInt64(data, at: offset + 8), extended >= 16 else { return nil }
                boxSize = extended
                headerSize = 16
            } else if size32 == 0 {
                boxSize = UInt64(data.count - offset)
            } else {
                boxSize = UInt64(size32)
            }
            guard type == "pssh", boxSize >= UInt64(headerSize + 24),
                  boxSize <= UInt64(Int.max),
                  offset <= data.count - Int(boxSize) else { return nil }

            let end = offset + Int(boxSize)
            var cursor = offset + headerSize
            guard cursor + 20 <= end else { return nil }
            let version = data[cursor]
            let highFlags = UInt32(data[cursor + 1]) << 16
            let middleFlags = UInt32(data[cursor + 2]) << 8
            let flags = highFlags | middleFlags | UInt32(data[cursor + 3])
            cursor += 4
            guard (version == 0 || version == 1), flags == 0,
                  let systemID = uuidString(data, at: cursor) else { return nil }
            cursor += 16

            var keyIDs: [String] = []
            if version == 1 {
                guard let keyCount32 = readUInt32(data, at: cursor),
                      keyCount32 <= UInt32(maximumKeyIDs) else { return nil }
                cursor += 4
                let keyCount = Int(keyCount32)
                guard keyCount <= (end - cursor) / 16 else { return nil }
                keyIDs.reserveCapacity(keyCount)
                for _ in 0..<keyCount {
                    guard let keyID = uuidString(data, at: cursor) else { return nil }
                    keyIDs.append(keyID)
                    cursor += 16
                }
            }

            guard let payloadSize32 = readUInt32(data, at: cursor) else { return nil }
            cursor += 4
            let payloadSize = Int(payloadSize32)
            guard payloadSize <= end - cursor, cursor + payloadSize == end else { return nil }
            let payload = data.subdata(in: cursor..<end)
            boxes.append(
                DASHPSSHBox(
                    rawData: data.subdata(in: offset..<end),
                    version: version,
                    flags: flags,
                    systemID: systemID,
                    keyIDs: keyIDs,
                    data: payload
                )
            )
            offset = end
        }
        return boxes.isEmpty ? nil : boxes
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let byte0 = UInt32(data[offset]) << 24
        let byte1 = UInt32(data[offset + 1]) << 16
        let byte2 = UInt32(data[offset + 2]) << 8
        return byte0 | byte1 | byte2 | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }

    private static func ascii(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return nil }
        return String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii)
    }

    private static func uuidString(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset <= data.count - 16 else { return nil }
        let bytes = data[offset..<(offset + 16)].map { String(format: "%02x", $0) }
        return bytes[0..<4].joined()
            + "-" + bytes[4..<6].joined()
            + "-" + bytes[6..<8].joined()
            + "-" + bytes[8..<10].joined()
            + "-" + bytes[10..<16].joined()
    }
}

private func xmlLocalName(_ elementName: String, qualifiedName: String?) -> String {
    let value = elementName.isEmpty ? (qualifiedName ?? "") : elementName
    return value.split(separator: ":").last.map(String.init) ?? value
}

private func isMPDRoot(_ localName: String, namespaceURI: String?) -> Bool {
    guard localName == "MPD" else { return false }
    guard let namespaceURI, !namespaceURI.isEmpty else { return true }
    return namespaceURI == DASHManifestParser.namespace
}

private func attribute(_ name: String, in attributes: [String: String]) -> String? {
    let expected = name.lowercased()
    return attributes.first { key, _ in
        let local = key.split(separator: ":").last.map(String.init) ?? key
        return local.lowercased() == expected
    }?.value
}

private func unsignedAttribute(_ name: String, in attributes: [String: String]) -> UInt64? {
    attribute(name, in: attributes).flatMap(UInt64.init)
}

private func signedAttribute(_ name: String, in attributes: [String: String]) -> Int64? {
    attribute(name, in: attributes).flatMap(Int64.init)
}

private func parseUUIDList(_ value: String?) -> [String] {
    guard let value else { return [] }
    return value
        .split(whereSeparator: { $0.isWhitespace || $0 == "," })
        .compactMap { UUID(uuidString: String($0))?.uuidString.lowercased() }
}

private func inferMediaType(contentType: String?, mimeType: String?, codecs: String?) -> DASHMediaType {
    switch contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "audio": return .audio
    case "video": return .video
    case "text", "subtitle", "subtitles": return .text
    default: break
    }
    let mime = mimeType?.lowercased() ?? ""
    if mime.hasPrefix("audio/") { return .audio }
    if mime.hasPrefix("video/") { return .video }
    if mime.hasPrefix("text/") || mime.contains("ttml") || mime.contains("vtt") { return .text }
    let codec = codecs?.lowercased() ?? ""
    if codec.contains("avc") || codec.contains("hev") || codec.contains("hvc") || codec.contains("vp9") || codec.contains("av01") {
        return .video
    }
    if codec.contains("mp4a") || codec.contains("ac-3") || codec.contains("ec-3") || codec.contains("opus") {
        return .audio
    }
    return .unknown
}
