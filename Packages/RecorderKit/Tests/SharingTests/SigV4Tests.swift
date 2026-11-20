// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Sharing
import Testing

/// The signature a real provider checks (plan 5a, Review Focus 1). AWS's published vectors, copied as they are, and cases
/// A–E from the plan's independent reference (Python, `hashlib`/`hmac`), byte for byte.
@Suite struct SigV4Tests {
    /// AWS's SigV4 test suite (`get-vanilla`) and its signing-key example.
    static let suiteCredentials = S3Credentials(
        accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    /// The examples of S3's documentation ("Signature Calculations for the Authorization Header").
    static let s3Credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    static let s3Date = date(2013, 5, 24, 0, 0, 0)
    static let referenceDate = date(2026, 11, 20, 12, 0, 0)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func hex(_ data: some Sequence<UInt8>) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    /// The `Signature=` part of an `Authorization` header.
    static func signature(of authorization: String?) -> String? {
        authorization?.components(separatedBy: "Signature=").last
    }

    static func signedHeaders(of authorization: String?) -> String? {
        guard let authorization, let range = authorization.range(of: "SignedHeaders=") else { return nil }
        return String(authorization[range.upperBound...].prefix { $0 != "," })
    }

    @Test func derivesTheSigningKeyOfAWSsExample() {
        let key = SigV4.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", dateStamp: "20120215", region: "us-east-1", service: "iam")
        let bytes = key.withUnsafeBytes { Array($0) }
        #expect(Self.hex(bytes) == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test func getVanillaMatchesTheSuite() {
        let date = Self.date(2015, 8, 30, 12, 36, 0)
        let headers = ["Host": "example.amazonaws.com", "X-Amz-Date": "20150830T123600Z"]
        let canonical = SigV4.canonicalRequest(
            method: "GET", encodedPath: "/", query: [], headers: headers, payloadHash: SigV4.emptyPayloadHash)
        #expect(
            canonical.text
                == "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n"
                + "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(canonical.signedHeaders == "host;x-amz-date")
        #expect(Self.sha256(canonical.text) == "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63")
        let signer = SigV4(credentials: Self.suiteCredentials, region: "us-east-1", service: "service")
        let authorization = signer.authorization(
            method: "GET", encodedPath: "/", query: [], headers: headers, payloadHash: SigV4.emptyPayloadHash, date: date)
        #expect(
            authorization
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, "
                + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func s3GetObjectExample() {
        let headers = [
            "Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9 ",
            "x-amz-content-sha256": SigV4.emptyPayloadHash, "x-amz-date": "20130524T000000Z ",
        ]
        let canonical = SigV4.canonicalRequest(
            method: "GET", encodedPath: "/test.txt", query: [], headers: headers, payloadHash: SigV4.emptyPayloadHash)
        #expect(Self.sha256(canonical.text) == "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        let signer = SigV4(credentials: Self.s3Credentials, region: "us-east-1")
        let authorization = signer.authorization(
            method: "GET", encodedPath: "/test.txt", query: [], headers: headers, payloadHash: SigV4.emptyPayloadHash,
            date: Self.s3Date)
        #expect(
            authorization
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func s3PutObjectExample() {
        let body = "Welcome to Amazon S3."
        let payloadHash = Self.sha256(body)
        #expect(payloadHash == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let path = SigV4.uriEncode("/test$file.text", encodeSlash: false)
        #expect(path == "/test%24file.text")
        let headers = [
            "Host": "examplebucket.s3.amazonaws.com", "Date": "Fri, 24 May 2013 00:00:00 GMT",
            "x-amz-date": "20130524T000000Z", "x-amz-storage-class": "REDUCED_REDUNDANCY",
            "x-amz-content-sha256": payloadHash,
        ]
        let canonical = SigV4.canonicalRequest(
            method: "PUT", encodedPath: path, query: [], headers: headers, payloadHash: payloadHash)
        #expect(Self.sha256(canonical.text) == "9e0e90d9c76de8fa5b200d8c849cd5b8dc7a3be3951ddb7f6a76b4158342019d")
        let signer = SigV4(credentials: Self.s3Credentials, region: "us-east-1")
        let authorization = signer.authorization(
            method: "PUT", encodedPath: path, query: [], headers: headers, payloadHash: payloadHash, date: Self.s3Date)
        #expect(Self.signedHeaders(of: authorization) == "date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class")
        #expect(Self.signature(of: authorization) == "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    }

    @Test func s3QueryExamples() {
        let headers = [
            "Host": "examplebucket.s3.amazonaws.com", "x-amz-date": "20130524T000000Z",
            "x-amz-content-sha256": SigV4.emptyPayloadHash,
        ]
        let signer = SigV4(credentials: Self.s3Credentials, region: "us-east-1")
        #expect(SigV4.canonicalQuery([("lifecycle", "")]) == "lifecycle=")
        let lifecycle = signer.authorization(
            method: "GET", encodedPath: "/", query: [("lifecycle", "")], headers: headers,
            payloadHash: SigV4.emptyPayloadHash, date: Self.s3Date)
        #expect(Self.signature(of: lifecycle) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
        #expect(SigV4.canonicalQuery([("prefix", "J"), ("max-keys", "2")]) == "max-keys=2&prefix=J")
        let list = signer.authorization(
            method: "GET", encodedPath: "/", query: [("prefix", "J"), ("max-keys", "2")], headers: headers,
            payloadHash: SigV4.emptyPayloadHash, date: Self.s3Date)
        #expect(Self.signature(of: list) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func s3PresignedURLExample() {
        let canonical = SigV4.canonicalRequest(
            method: "GET", encodedPath: "/test.txt",
            query: [
                ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
                ("X-Amz-Credential", "AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"),
                ("X-Amz-Date", "20130524T000000Z"), ("X-Amz-Expires", "86400"), ("X-Amz-SignedHeaders", "host"),
            ],
            headers: ["Host": "examplebucket.s3.amazonaws.com"], payloadHash: SigV4.unsignedPayload)
        #expect(Self.sha256(canonical.text) == "3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04")
        let signer = SigV4(credentials: Self.s3Credentials, region: "us-east-1")
        let url = signer.presignedURL(
            method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, expires: 86_400,
            date: Self.s3Date)
        #expect(
            url.absoluteString
                == "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                + "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                + "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
                + "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    @Test func streamingSeedSignature() {
        let headers = [
            "Host": "s3.amazonaws.com", "x-amz-date": "20130524T000000Z", "x-amz-storage-class": "REDUCED_REDUNDANCY",
            "x-amz-content-sha256": "STREAMING-AWS4-HMAC-SHA256-PAYLOAD", "Content-Encoding": "aws-chunked",
            "x-amz-decoded-content-length": "66560", "Content-Length": "66824",
        ]
        let signer = SigV4(credentials: Self.s3Credentials, region: "us-east-1")
        let authorization = signer.authorization(
            method: "PUT", encodedPath: "/examplebucket/chunkObject.txt", query: [], headers: headers,
            payloadHash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD", date: Self.s3Date)
        #expect(
            Self.signedHeaders(of: authorization)
                == "content-encoding;content-length;host;x-amz-content-sha256;x-amz-date;x-amz-decoded-content-length;"
                + "x-amz-storage-class")
        #expect(Self.signature(of: authorization) == "4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9")
    }

    // MARK: - Cases A–E of the plan's reference

    /// The configuration the reference cases sign with: R2 (region `auto`) unless a case says otherwise.
    static func configuration(
        provider: ShareProvider = .r2, endpoint: String = "https://0123456789abcdef.r2.cloudflarestorage.com",
        region: String = "auto", bucket: String = "bucket"
    ) throws -> ShareConfiguration {
        try ShareConfiguration(
            preferences: SharePreferences(
                provider: provider, endpoint: endpoint, region: region, bucket: bucket, prefix: "toma/",
                accessKeyID: "AKIDEXAMPLE"),
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    }

    @Test func presignMatchesTheReference() throws {
        let configuration = try Self.configuration(
            provider: .minio, endpoint: "http://localhost:9000", region: "us-east-1", bucket: "toma-bucket")
        let object = configuration.objectURL(key: "toma/ab cd/ñ.mp4")
        #expect(object.absoluteString == "http://localhost:9000/toma-bucket/toma/ab%20cd/%C3%B1.mp4")
        let signer = SigV4(credentials: configuration.credentials, region: configuration.region)
        let url = signer.presignedURL(method: "GET", url: object, expires: 604_800, date: Self.referenceDate)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/toma-bucket/toma/ab%20cd/%C3%B1.mp4")
        #expect(components.host == "localhost" && components.port == 9000)
        let items = components.queryItems ?? []
        #expect(items.first { $0.name == "X-Amz-Expires" }?.value == "604800")
        #expect(items.first { $0.name == "X-Amz-SignedHeaders" }?.value == "host")
        #expect(
            items.first { $0.name == "X-Amz-Signature" }?.value
                == "9a0e1a4a3e27d6aebd197f3ab50cc0ba52732981916e5b39aa8639b2959dcb4e")
        #expect(items.last?.name == "X-Amz-Signature")
    }

    @Test func putWithContentTypeMatchesTheReference() throws {
        let configuration = try Self.configuration()
        let body = Data("Toma".utf8)
        let payloadHash = Self.hex(SHA256.hash(data: body))
        #expect(payloadHash == "c5231cee1d80cdcdf040eb9caa4fc651b627f7fb80835089cd955b242e8cae14")
        var request = URLRequest(url: configuration.objectURL(key: "toma/.toma-connection-test-k3m7q2x9za.txt"))
        request.httpMethod = "PUT"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let signed = SigV4(credentials: configuration.credentials, region: configuration.region)
            .signed(request, payloadHash: payloadHash, date: Self.referenceDate)
        let authorization = signed.value(forHTTPHeaderField: "Authorization")
        #expect(signed.url?.absoluteString
            == "https://0123456789abcdef.r2.cloudflarestorage.com/bucket/toma/.toma-connection-test-k3m7q2x9za.txt")
        #expect(Self.signedHeaders(of: authorization) == "content-type;host;x-amz-content-sha256;x-amz-date")
        #expect(signed.value(forHTTPHeaderField: "x-amz-content-sha256") == payloadHash)
        #expect(signed.value(forHTTPHeaderField: "x-amz-date") == "20261120T120000Z")
        #expect(authorization?.contains("Credential=AKIDEXAMPLE/20261120/auto/s3/aws4_request,") == true)
        #expect(Self.signature(of: authorization) == "b5980f1e4768f4affe7a7dd41b13b46649938c545187dd4aa5ec1c60aad66362")
    }

    @Test func uploadPartQueryMatchesTheReference() throws {
        let configuration = try Self.configuration()
        let signer = SigV4(credentials: configuration.credentials, region: configuration.region)
        let object = configuration.objectURL(key: "toma/k3m7q2x9za/video.mp4")
        var part = URLRequest(
            url: URL(string: object.absoluteString + "?partNumber=2&uploadId=2~iCw_lDY8VoNMv1ZQB8pPzpVhNk0iV")!)
        part.httpMethod = "PUT"
        let partSigned = signer.signed(
            part, payloadHash: Self.hex(SHA256.hash(data: Data("part-2".utf8))), date: Self.referenceDate)
        let partAuthorization = partSigned.value(forHTTPHeaderField: "Authorization")
        #expect(Self.signedHeaders(of: partAuthorization) == "host;x-amz-content-sha256;x-amz-date")
        #expect(
            Self.signature(of: partAuthorization) == "fac81f268755e4a343e32ad9246f87b1fd0287aaee036b5218a3f4a6b3a106e7")

        var create = URLRequest(url: URL(string: object.absoluteString + "?uploads")!)
        create.httpMethod = "POST"
        let createSigned = signer.signed(create, payloadHash: SigV4.emptyPayloadHash, date: Self.referenceDate)
        #expect(
            Self.signature(of: createSigned.value(forHTTPHeaderField: "Authorization"))
                == "d2e6c8655b14a4dd00b7156b8e9a5a4a6d668fb052606b1c48f84ed8fa1cddc7")
    }

    @Test func virtualHostedDeleteMatchesTheReference() throws {
        let configuration = try Self.configuration(
            provider: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "my-bucket")
        var request = URLRequest(url: configuration.objectURL(key: "toma/k3m7q2x9za/poster.jpg"))
        #expect(request.url?.absoluteString == "https://my-bucket.s3.eu-west-1.amazonaws.com/toma/k3m7q2x9za/poster.jpg")
        request.httpMethod = "DELETE"
        let signed = SigV4(credentials: configuration.credentials, region: configuration.region)
            .signed(request, payloadHash: SigV4.emptyPayloadHash, date: Self.referenceDate)
        #expect(
            Self.signature(of: signed.value(forHTTPHeaderField: "Authorization"))
                == "cb38480d9fb0c34362f7f97315d9a6beaa77c9346122a67d7c2a8dd5e3899841")
    }

    @Test func uriEncodeKeepsUnreservedAndEncodesTheRest() {
        #expect(SigV4.uriEncode("a-_.~Z9", encodeSlash: true) == "a-_.~Z9")
        #expect(SigV4.uriEncode(" ", encodeSlash: true) == "%20")
        #expect(SigV4.uriEncode("ñ", encodeSlash: true) == "%C3%B1")
        #expect(SigV4.uriEncode("+", encodeSlash: true) == "%2B")
        #expect(SigV4.uriEncode("*", encodeSlash: true) == "%2A")
        #expect(SigV4.uriEncode("a/b", encodeSlash: false) == "a/b")
        #expect(SigV4.uriEncode("a/b", encodeSlash: true) == "a%2Fb")
        #expect(SigV4.canonicalQuery([("k", "a/b")]) == "k=a%2Fb")
    }

    @Test func amzDateIsUTC() {
        #expect(SigV4.amzDate(Self.s3Date) == "20130524T000000Z")
        // Half a second later is still the same second: the date is cut, never rounded up.
        #expect(SigV4.amzDate(Self.s3Date.addingTimeInterval(0.999)) == "20130524T000000Z")
        #expect(SigV4.amzDate(Self.date(2026, 12, 31, 23, 59, 59)) == "20261231T235959Z")
    }
}
