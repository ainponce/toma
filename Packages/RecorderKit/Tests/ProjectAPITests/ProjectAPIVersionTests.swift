// SPDX-License-Identifier: GPL-3.0-or-later
@testable import ProjectAPI
import Testing

@Test func projectAPIHasVersion1() {
    #expect(ProjectAPI.version == "1.0")
}
