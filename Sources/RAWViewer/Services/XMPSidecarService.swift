import Foundation

enum XMPSidecarError: LocalizedError {
    case unsupportedPhoto
    case unsafeExistingFile(String)
    case fileTooLarge(Int64)
    case invalidDocument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPhoto:
            "Für dieses Dateiformat wird kein externes XMP-Sidecar geschrieben."
        case .unsafeExistingFile(let message):
            "Das vorhandene XMP-Sidecar ist nicht sicher beschreibbar: \(message)"
        case .fileTooLarge(let byteCount):
            "Das vorhandene XMP-Sidecar ist mit \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) ungewöhnlich groß."
        case .invalidDocument(let message):
            "Das vorhandene XMP-Sidecar ist ungültig: \(message)"
        }
    }
}

enum XMPSidecarWriteResult: Sendable {
    case created(URL)
    case updated(URL)
    case unchanged(URL)

    var url: URL {
        switch self {
        case .created(let url), .updated(let url), .unchanged(let url): url
        }
    }
}

struct XMPSidecarService: Sendable {
    private static let maximumExistingFileSize: Int64 = 16 * 1_024 * 1_024
    private static let fileAccessLock = NSLock()
    private static let xmpNamespace = "adobe:ns:meta/"
    private static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    private static let tiffNamespace = "http://ns.adobe.com/tiff/1.0/"

    func sidecarURL(for asset: PhotoAsset) -> URL? {
        guard let rawURL = asset.rawURL else { return nil }
        let fileExtension = rawURL.pathExtension.lowercased()
        guard fileExtension != "dng" else { return nil }
        return rawURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    func writeKeywords(
        _ keywords: [String],
        replacingPersonKeywords previousKeywords: [String] = [],
        for asset: PhotoAsset
    ) throws -> XMPSidecarWriteResult {
        Self.fileAccessLock.lock()
        defer { Self.fileAccessLock.unlock() }
        guard let sidecarURL = sidecarURL(for: asset) else { throw XMPSidecarError.unsupportedPhoto }
        let normalizedKeywords = normalized(keywords)
        let desiredKeys = Set(normalizedKeywords.map(comparisonKey))
        let removablePersonKeys = Set(previousKeywords
            .filter(isPersonKeyword)
            .map(comparisonKey))
            .subtracting(desiredKeys)
        guard !normalizedKeywords.isEmpty || !removablePersonKeys.isEmpty else {
            throw XMPSidecarError.invalidDocument("Es sind keine exportierbaren Schlagwörter vorhanden.")
        }

        let fileManager = FileManager.default
        let existed = fileManager.fileExists(atPath: sidecarURL.path)
        let document: XMLDocument
        var existingData: Data?

        if existed {
            let values = try sidecarURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
            guard values.isRegularFile == true else {
                throw XMPSidecarError.unsafeExistingFile("Es ist keine reguläre Datei.")
            }
            guard values.isSymbolicLink != true else {
                throw XMPSidecarError.unsafeExistingFile("Symbolische Links werden nicht überschrieben.")
            }
            let byteCount = Int64(values.fileSize ?? 0)
            guard byteCount <= Self.maximumExistingFileSize else {
                throw XMPSidecarError.fileTooLarge(byteCount)
            }
            let data = try Data(contentsOf: sidecarURL, options: .mappedIfSafe)
            existingData = data
            let preview = String(decoding: data.prefix(8_192), as: UTF8.self).uppercased()
            guard !preview.contains("<!DOCTYPE"), !preview.contains("<!ENTITY") else {
                throw XMPSidecarError.unsafeExistingFile("Dokumenttyp- und Entity-Deklarationen werden nicht verarbeitet.")
            }
            do {
                document = try XMLDocument(
                    data: data,
                    options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
                )
            } catch {
                throw XMPSidecarError.invalidDocument(error.localizedDescription)
            }
            guard document.dtd == nil else {
                throw XMPSidecarError.unsafeExistingFile("Dokumenttyp-Deklarationen werden nicht verarbeitet.")
            }
        } else {
            document = makeDocument()
        }

        let description = try rdfDescription(in: document)
        ensureNamespace(prefix: "dc", uri: Self.dcNamespace, on: description)
        let subject = try subjectElement(in: description)
        let container = try keywordContainer(in: subject)
        let keywordNodes = try container.nodes(forXPath: "./*[local-name()='li']")
        var changed = false
        for node in keywordNodes {
            guard let value = node.stringValue,
                  removablePersonKeys.contains(comparisonKey(value)) else { continue }
            node.detach()
            changed = true
        }
        let existingKeywords = try container.nodes(forXPath: "./*[local-name()='li']").compactMap(\.stringValue)
        var seen = Set(existingKeywords.map(comparisonKey))

        for keyword in normalizedKeywords where seen.insert(comparisonKey(keyword)).inserted {
            container.addChild(XMLElement(name: "rdf:li", stringValue: keyword))
            changed = true
        }

        if existed, !changed {
            return .unchanged(sidecarURL)
        }

        let output = document.xmlData(options: [.nodePrettyPrint])
        if output == existingData {
            return .unchanged(sidecarURL)
        }
        try output.write(to: sidecarURL, options: .atomic)
        return existed ? .updated(sidecarURL) : .created(sidecarURL)
    }

    func orientation(for asset: PhotoAsset) throws -> Int? {
        Self.fileAccessLock.lock()
        defer { Self.fileAccessLock.unlock() }
        guard let sidecarURL = sidecarURL(for: asset) else { throw XMPSidecarError.unsupportedPhoto }
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return nil }
        let document = try readDocument(at: sidecarURL)
        let description = try rdfDescription(in: document)
        return orientation(in: description)
    }

    func writeOrientation(_ desiredOrientation: Int?, for asset: PhotoAsset) throws -> XMPSidecarWriteResult {
        Self.fileAccessLock.lock()
        defer { Self.fileAccessLock.unlock() }
        if let desiredOrientation, !(1...8).contains(desiredOrientation) {
            throw XMPSidecarError.invalidDocument("Der XMP-Orientierungswert muss zwischen 1 und 8 liegen.")
        }
        guard let sidecarURL = sidecarURL(for: asset) else { throw XMPSidecarError.unsupportedPhoto }
        let existed = FileManager.default.fileExists(atPath: sidecarURL.path)
        guard existed || desiredOrientation != nil else { return .unchanged(sidecarURL) }

        let document = try existed ? readDocument(at: sidecarURL) : makeDocument()
        let existingData = existed ? try Data(contentsOf: sidecarURL, options: .mappedIfSafe) : nil
        let description = try rdfDescription(in: document)
        let existingOrientation = orientation(in: description)
        guard existingOrientation != desiredOrientation else { return .unchanged(sidecarURL) }

        let orientationAttributes = (description.attributes ?? []).filter {
            $0.localName == "Orientation" || $0.name == "tiff:Orientation"
        }
        let orientationElements = try description.nodes(forXPath: "./*[local-name()='Orientation']")
        for node in orientationAttributes + orientationElements {
            node.detach()
        }

        if let desiredOrientation {
            ensureNamespace(prefix: "tiff", uri: Self.tiffNamespace, on: description)
            description.addAttribute(
                XMLNode.attribute(withName: "tiff:Orientation", stringValue: String(desiredOrientation)) as! XMLNode
            )
        }

        let output = document.xmlData(options: [.nodePrettyPrint])
        if output == existingData { return .unchanged(sidecarURL) }
        try output.write(to: sidecarURL, options: .atomic)
        return existed ? .updated(sidecarURL) : .created(sidecarURL)
    }

    private func readDocument(at sidecarURL: URL) throws -> XMLDocument {
        let values = try sidecarURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true else {
            throw XMPSidecarError.unsafeExistingFile("Es ist keine reguläre Datei.")
        }
        guard values.isSymbolicLink != true else {
            throw XMPSidecarError.unsafeExistingFile("Symbolische Links werden nicht überschrieben.")
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount <= Self.maximumExistingFileSize else {
            throw XMPSidecarError.fileTooLarge(byteCount)
        }
        let data = try Data(contentsOf: sidecarURL, options: .mappedIfSafe)
        let preview = String(decoding: data.prefix(8_192), as: UTF8.self).uppercased()
        guard !preview.contains("<!DOCTYPE"), !preview.contains("<!ENTITY") else {
            throw XMPSidecarError.unsafeExistingFile("Dokumenttyp- und Entity-Deklarationen werden nicht verarbeitet.")
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(
                data: data,
                options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
            )
        } catch {
            throw XMPSidecarError.invalidDocument(error.localizedDescription)
        }
        guard document.dtd == nil else {
            throw XMPSidecarError.unsafeExistingFile("Dokumenttyp-Deklarationen werden nicht verarbeitet.")
        }
        return document
    }

    private func orientation(in description: XMLElement) -> Int? {
        let attributeValue = (description.attributes ?? []).first {
            $0.localName == "Orientation" || $0.name == "tiff:Orientation"
        }?.stringValue
        let elementValue = try? description.nodes(
            forXPath: "./*[local-name()='Orientation']"
        ).first?.stringValue
        guard let value = attributeValue ?? elementValue,
              let orientation = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...8).contains(orientation) else { return nil }
        return orientation
    }

    private func makeDocument() -> XMLDocument {
        let xmpmeta = XMLElement(name: "x:xmpmeta")
        xmpmeta.addNamespace(XMLNode.namespace(withName: "x", stringValue: Self.xmpNamespace) as! XMLNode)

        let rdf = XMLElement(name: "rdf:RDF")
        rdf.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: Self.rdfNamespace) as! XMLNode)
        xmpmeta.addChild(rdf)

        let description = XMLElement(name: "rdf:Description")
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
        rdf.addChild(description)

        let document = XMLDocument(rootElement: xmpmeta)
        document.version = "1.0"
        document.characterEncoding = "UTF-8"
        return document
    }

    private func rdfDescription(in document: XMLDocument) throws -> XMLElement {
        let nodes = try document.nodes(
            forXPath: "//*[local-name()='RDF']/*[local-name()='Description']"
        )
        guard let description = nodes.first as? XMLElement else {
            throw XMPSidecarError.invalidDocument("Es fehlt rdf:Description.")
        }
        return description
    }

    private func subjectElement(in description: XMLElement) throws -> XMLElement {
        if let subject = try description.nodes(
            forXPath: "./*[local-name()='subject']"
        ).first as? XMLElement {
            return subject
        }
        let subject = XMLElement(name: "dc:subject")
        description.addChild(subject)
        return subject
    }

    private func keywordContainer(in subject: XMLElement) throws -> XMLElement {
        if let container = try subject.nodes(
            forXPath: "./*[local-name()='Bag' or local-name()='Seq' or local-name()='Alt']"
        ).first as? XMLElement {
            return container
        }
        let container = XMLElement(name: "rdf:Bag")
        subject.addChild(container)
        return container
    }

    private func ensureNamespace(prefix: String, uri: String, on element: XMLElement) {
        guard element.namespace(forPrefix: prefix) == nil else { return }
        element.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
    }

    private func normalized(_ keywords: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in keywords {
            let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = comparisonKey(keyword)
            guard keyword.count >= 2, seen.insert(key).inserted else { continue }
            result.append(keyword)
        }
        return result
    }

    private func comparisonKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }

    private func isPersonKeyword(_ value: String) -> Bool {
        comparisonKey(value).hasPrefix("person: ")
    }
}
