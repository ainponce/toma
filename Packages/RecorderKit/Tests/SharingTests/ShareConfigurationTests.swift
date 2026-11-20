// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Sharing
import Testing

@Suite struct ShareConfigurationTests {
    static let secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"

    static func preferences(
        provider: ShareProvider = .r2, endpoint: String = "https://e", region: String = "auto",
        bucket: String = "bucket", prefix: String = "toma/", publicBaseURL: String = "", linkDays: Int = 7
    ) -> SharePreferences {
        SharePreferences(
            provider: provider, endpoint: endpoint, region: region, bucket: bucket, prefix: prefix,
            accessKeyID: "AKIDEXAMPLE", publicBaseURL: publicBaseURL, linkDays: linkDays)
    }

    static func problem(_ preferences: SharePreferences) -> ShareConfigurationProblem? {
        do {
            _ = try ShareConfiguration(preferences: preferences, secret: secret)
            return nil
        } catch {
            return error
        }
    }

    @Test func preferencesDefaultToR2WithTheTomaPrefix() {
        let preferences = SharePreferences()
        #expect(preferences.provider == .r2 && preferences.region == "auto" && preferences.prefix == "toma/")
        #expect(preferences.endpoint.isEmpty && preferences.bucket.isEmpty && preferences.linkDays == 7)
    }

    @Test func plainHTTPOnlyForLocalhost() throws {
        for endpoint in ["http://localhost:9000", "http://127.0.0.1:9000", "http://[::1]:9000", "https://minio.lan"] {
            #expect(Self.problem(Self.preferences(provider: .minio, endpoint: endpoint)) == nil, "\(endpoint)")
        }
        #expect(Self.problem(Self.preferences(endpoint: "http://minio.lan")) == .insecureEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "http://localhost.example.com")) == .insecureEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "ftp://localhost")) == .invalidEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "https://x/bucket")) == .invalidEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "https://x?a=b")) == .invalidEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "https://user:pw@x")) == .invalidEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "nada")) == .invalidEndpoint)
        #expect(Self.problem(Self.preferences(endpoint: "   ")) == .missingEndpoint)
        // A trailing slash is no path; the endpoint keeps only its scheme, host and port.
        let configuration = try ShareConfiguration(
            preferences: Self.preferences(provider: .minio, endpoint: " http://[::1]:9000/ "), secret: Self.secret)
        #expect(configuration.endpoint.absoluteString == "http://[::1]:9000")
        #expect(configuration.objectURL(key: "toma/a.txt").absoluteString == "http://[::1]:9000/bucket/toma/a.txt")
        // The scheme's own port is dropped (review M4): the URL and the signed host agree with what URLSession sends.
        let defaultPort = try ShareConfiguration(
            preferences: Self.preferences(endpoint: "https://E.example.com:443/", publicBaseURL: "https://p.example.com:443/v"),
            secret: Self.secret)
        #expect(defaultPort.endpoint.absoluteString == "https://e.example.com")
        #expect(defaultPort.publicBaseURL?.absoluteString == "https://p.example.com/v")
        let local = try ShareConfiguration(preferences: Self.preferences(endpoint: "http://localhost:80"), secret: Self.secret)
        #expect(local.endpoint.absoluteString == "http://localhost")
    }

    @Test func publicBaseNeedsHTTPS() throws {
        #expect(Self.problem(Self.preferences(publicBaseURL: "http://pub.example.com")) == .insecurePublicURL)
        #expect(Self.problem(Self.preferences(publicBaseURL: "nada")) == .invalidPublicURL)
        #expect(Self.problem(Self.preferences(publicBaseURL: "https://pub.example.com/?x=1")) == .invalidPublicURL)
        let none = try ShareConfiguration(preferences: Self.preferences(publicBaseURL: ""), secret: Self.secret)
        #expect(none.publicBaseURL == nil && none.publicURL(key: "toma/x/index.html") == nil)
        let local = try ShareConfiguration(
            preferences: Self.preferences(publicBaseURL: "http://localhost:9000/bucket"), secret: Self.secret)
        #expect(local.publicURL(key: "toma/x/index.html")?.absoluteString == "http://localhost:9000/bucket/toma/x/index.html")
        let configuration = try ShareConfiguration(
            preferences: Self.preferences(publicBaseURL: "https://pub-1.r2.dev/"), secret: Self.secret)
        #expect(configuration.publicBaseURL?.absoluteString == "https://pub-1.r2.dev")
        #expect(
            configuration.publicURL(key: "toma/a b/index.html")?.absoluteString
                == "https://pub-1.r2.dev/toma/a%20b/index.html")
    }

    @Test func prefixIsNormalized() throws {
        let cases: [(String, String)] = [("toma", "toma/"), ("/toma/", "toma/"), ("", ""), ("a//b", "a/b/"), (" toma/x ", "toma/x/")]
        for (written, normalized) in cases {
            let configuration = try ShareConfiguration(preferences: Self.preferences(prefix: written), secret: Self.secret)
            #expect(configuration.prefix == normalized, "\(written)")
        }
        #expect(Self.problem(Self.preferences(prefix: "a/../b")) == .invalidPrefix)
        #expect(Self.problem(Self.preferences(prefix: "..")) == .invalidPrefix)
        #expect(Self.problem(Self.preferences(prefix: "a/./b")) == .invalidPrefix)
    }

    @Test func bucketsAreChecked() {
        #expect(Self.problem(Self.preferences(bucket: " ")) == .missingBucket)
        for bucket in ["a/b", "a b", "a..b", "a?b", "a#b"] {
            #expect(Self.problem(Self.preferences(bucket: bucket)) == .invalidBucket, "\(bucket)")
        }
        #expect(Self.problem(Self.preferences(bucket: "my.bucket-1_x")) == nil)
    }

    @Test func linkDaysClampToOneThroughSeven() throws {
        for (days, lifetime) in [(0, 86_400), (3, 259_200), (9, 604_800), (-4, 86_400), (7, 604_800)] {
            let configuration = try ShareConfiguration(preferences: Self.preferences(linkDays: days), secret: Self.secret)
            #expect(configuration.linkLifetime == lifetime)
        }
    }

    @Test func objectURLsByAddressing() throws {
        let r2 = try ShareConfiguration(preferences: Self.preferences(), secret: Self.secret)
        #expect(r2.addressing == .path)
        #expect(r2.objectURL(key: "toma/x/video.mp4").absoluteString == "https://e/bucket/toma/x/video.mp4")
        let s3 = try ShareConfiguration(
            preferences: Self.preferences(provider: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1"),
            secret: Self.secret)
        #expect(s3.addressing == .virtualHosted)
        #expect(
            s3.objectURL(key: "toma/x/video.mp4").absoluteString
                == "https://bucket.s3.eu-west-1.amazonaws.com/toma/x/video.mp4")
        let dotted = try ShareConfiguration(
            preferences: Self.preferences(
                provider: .s3, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1", bucket: "my.bucket"),
            secret: Self.secret)
        #expect(dotted.addressing == .path)
        // A bucket that is no host name's label (capitals, "_") is addressed by path too (review M5).
        for bucket in ["MyBucket", "my_bucket"] {
            let legacy = try ShareConfiguration(
                preferences: Self.preferences(
                    provider: .s3, endpoint: "https://s3.us-east-1.amazonaws.com", region: "us-east-1", bucket: bucket),
                secret: Self.secret)
            #expect(legacy.addressing == .path, "\(bucket)")
            #expect(legacy.objectURL(key: "a").absoluteString == "https://s3.us-east-1.amazonaws.com/\(bucket)/a")
        }
        #expect(
            dotted.objectURL(key: "toma/x/video.mp4").absoluteString
                == "https://s3.eu-west-1.amazonaws.com/my.bucket/toma/x/video.mp4")
        // Every segment of a key is encoded once: what URLSession sends is what was signed.
        #expect(
            r2.objectURL(key: "toma/ab cd/ñ+1.mp4").absoluteString == "https://e/bucket/toma/ab%20cd/%C3%B1%2B1.mp4")
        // An empty region signs with the service's own.
        let noRegion = try ShareConfiguration(preferences: Self.preferences(provider: .b2, region: " "), secret: Self.secret)
        #expect(noRegion.region == "us-west-004")
    }

    @Test func providerTemplates() {
        #expect(ShareProvider.s3.endpoint(region: "eu-west-1") == "https://s3.eu-west-1.amazonaws.com")
        #expect(ShareProvider.b2.endpoint(region: "us-west-004") == "https://s3.us-west-004.backblazeb2.com")
        #expect(ShareProvider.s3.endpoint(region: "eu west") == nil)
        #expect(ShareProvider.r2.endpoint(region: "auto") == nil)
        #expect(ShareProvider.minio.endpoint(region: "us-east-1") == nil)
        #expect(ShareProvider.other.endpoint(region: "us-east-1") == nil)
        #expect(ShareProvider.r2.defaultRegion == "auto")
        #expect(ShareProvider.s3.defaultRegion == "us-east-1")
        #expect(ShareProvider.b2.defaultRegion == "us-west-004")
        #expect(ShareProvider.minio.defaultRegion == "us-east-1")
        #expect(ShareProvider.other.defaultRegion == "us-east-1")
        #expect(ShareProvider.r2.endpointTemplate == "https://<ACCOUNT_ID>.r2.cloudflarestorage.com")
        #expect(ShareProvider.minio.endpointTemplate == "http://localhost:9000")
        #expect(ShareProvider.other.endpointTemplate.isEmpty)
        #expect(ShareProvider.allCases.filter { $0.addressing == .virtualHosted } == [.s3])
    }

    @Test func problemsListEverythingMissing() {
        #expect(
            ShareConfiguration.problems(in: SharePreferences(), hasSecret: false)
                == [.missingEndpoint, .missingBucket, .missingAccessKey, .missingSecret])
        #expect(ShareConfiguration.problems(in: Self.preferences(), hasSecret: true).isEmpty)
        #expect(
            ShareConfiguration.problems(
                in: Self.preferences(endpoint: "http://x", bucket: "a/b", prefix: "..", publicBaseURL: "http://p"),
                hasSecret: true) == [.insecureEndpoint, .invalidBucket, .invalidPrefix, .insecurePublicURL])
        #expect(throws: ShareConfigurationProblem.missingSecret) {
            try ShareConfiguration(preferences: Self.preferences(), secret: "")
        }
        // A region or an access key id that would break the signature's scope or its `Credential=` (review M6).
        for region in ["us east-1", "eu/west", "US-EAST-1"] {
            #expect(Self.problem(Self.preferences(region: region)) == .invalidRegion, "\(region)")
        }
        for id in ["AKID EXAMPLE", "AKID/1", "a,b", "clé"] {
            var preferences = Self.preferences()
            preferences.accessKeyID = id
            #expect(Self.problem(preferences) == .invalidAccessKey, "\(id)")
        }
        var minio = Self.preferences(provider: .minio, endpoint: "http://localhost:9000", region: "us-east-1")
        minio.accessKeyID = "minio_admin-1.x"
        #expect(Self.problem(minio) == nil)
    }

    @Test func credentialsNeverPrint() throws {
        let credentials = S3Credentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: Self.secret)
        let configuration = try ShareConfiguration(preferences: Self.preferences(), secret: Self.secret)
        var dumped = ""
        dump(credentials, to: &dumped)
        var dumpedConfiguration = ""
        dump(configuration, to: &dumpedConfiguration)
        let texts = [
            "\(credentials)", String(reflecting: credentials), dumped, "\(configuration)",
            String(reflecting: configuration), dumpedConfiguration,
            "\(SigV4(credentials: credentials, region: "auto"))", String(reflecting: [credentials]),
        ]
        for text in texts {
            #expect(!text.contains(Self.secret) && !text.contains("bPxRfiCY"), "\(text)")
        }
        #expect("\(credentials)".contains("AKIDEXAMPLE"))
    }
}
