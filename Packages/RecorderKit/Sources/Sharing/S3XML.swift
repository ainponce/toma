// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The little of S3's XML the client reads and writes (plan 5a, task S1): the `UploadId` of `CreateMultipartUpload`, the
/// `<Code>` of an `<Error>` (also in a 200: `CompleteMultipartUpload` can fail after answering), and the body of
/// `CompleteMultipartUpload`.
enum S3XML {
    /// The root element's name and the text of its direct children.
    struct Document: Equatable {
        var root: String
        var fields: [String: String]
    }

    /// The document in `data`, or `nil` when it is not XML. The whitespace S3 sends to keep a slow `Complete` alive may
    /// come before the declaration; it is skipped.
    static func document(_ data: Data) -> Document? {
        let start = data.firstIndex { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? data.endIndex
        guard start < data.endIndex else { return nil }
        let parser = XMLParser(data: Data(data[start...]))
        let reader = Reader()
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        guard parser.parse(), let root = reader.root else { return nil }
        return Document(root: root, fields: reader.fields)
    }

    /// The `UploadId` of an `InitiateMultipartUploadResult`.
    static func uploadID(in data: Data) -> String? {
        guard let document = document(data), document.root == "InitiateMultipartUploadResult",
            let id = document.fields["UploadId"], !id.isEmpty
        else { return nil }
        return id
    }

    /// The `<Code>` of an `<Error>` document; `nil` when the body is not one.
    static func errorCode(in data: Data) -> String? {
        guard let document = document(data), document.root == "Error" else { return nil }
        return document.fields["Code"] ?? ""
    }

    /// Whether `data` is a `CompleteMultipartUploadResult`: the only answer of `Complete` that is a success.
    static func isCompleteResult(_ data: Data) -> Bool {
        document(data)?.root == "CompleteMultipartUploadResult"
    }

    /// `<CompleteMultipartUpload>` with each part, in the order given, its ETag as the part's PUT returned it.
    static func completeBody(parts: [(number: Int, etag: String)]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for part in parts {
            xml += "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(escaped(part.etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    /// Text escaped for an element's content. A quote needs no escaping there, and S3 compares ETags as written.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Reads the root's name and the text of its direct children; deeper elements are ignored.
    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var fields: [String: String] = [:]
        private var depth = 0
        private var field: String?
        private var text = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            depth += 1
            if depth == 1 {
                root = elementName
            } else if depth == 2 {
                field = elementName
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if depth == 2 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 2, let field, fields[field] == nil { fields[field] = text }
            if depth == 2 { field = nil }
            depth -= 1
        }
    }
}
