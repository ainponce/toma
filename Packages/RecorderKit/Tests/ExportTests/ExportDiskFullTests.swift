// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import Export
import Foundation
import Testing

// A full disk is its own export error, with its own sentence in the app (final review C-M3), whether AVFoundation's
// writer, the sync or the move into place says so.
@Test func aFullDiskIsToldApart() {
    #expect(ExportError.isDiskFull(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)))
    #expect(ExportError.isDiskFull(POSIXError(.ENOSPC)))
    #expect(ExportError.isDiskFull(POSIXError(.EDQUOT)))
    #expect(ExportError.isDiskFull(CocoaError(.fileWriteOutOfSpace)))
    // AVFoundation's writer wraps the system's error.
    let wrapped = NSError(
        domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
    #expect(ExportError.isDiskFull(wrapped))
    #expect(!ExportError.isDiskFull(POSIXError(.EIO)))
    #expect(!ExportError.isDiskFull(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderNotFound.rawValue)))
    #expect(ExportError.diskFull != .writerFailed(""))
}
