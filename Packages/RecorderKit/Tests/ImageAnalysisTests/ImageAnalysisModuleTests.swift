// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
// @testable only for the module's internal, empty marker: the first task that fills the module replaces this test.
@testable import ImageAnalysis

@Test func theModuleIsThere() {
    #expect(String(describing: ImageAnalysisModule.self) == "ImageAnalysisModule")
}
