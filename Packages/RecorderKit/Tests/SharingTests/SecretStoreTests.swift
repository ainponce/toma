// SPDX-License-Identifier: GPL-3.0-or-later
import Sharing
import Testing

// The secret store the tests use: no test ever reads or writes the system's.

@Suite struct SecretStoreTests {
    @Test func inMemoryRoundTripsAndNilRemoves() throws {
        let store = InMemorySecretStore(["AKIDEXAMPLE": "first"])
        #expect(try store.secret(for: "AKIDEXAMPLE") == "first")
        #expect(try store.secret(for: "AKIAIOSFODNN7EXAMPLE") == nil)
        try store.setSecret("second", for: "AKIDEXAMPLE")
        try store.setSecret("other", for: "AKIAIOSFODNN7EXAMPLE")
        #expect(try store.secret(for: "AKIDEXAMPLE") == "second")
        try store.setSecret(nil, for: "AKIDEXAMPLE")
        #expect(try store.secret(for: "AKIDEXAMPLE") == nil)
        // Removing what is not there is not an error; the other account is untouched.
        try store.setSecret(nil, for: "AKIDEXAMPLE")
        #expect(try store.secret(for: "AKIAIOSFODNN7EXAMPLE") == "other")
        #expect(try InMemorySecretStore().secret(for: "") == nil)
    }

    @Test func theAccountIsTheAccessKeyIDTrimmed() {
        #expect(SharePreferences(accessKeyID: "  AKIDEXAMPLE\n").secretAccount == "AKIDEXAMPLE")
        #expect(SharePreferences().secretAccount == "")
    }
}
