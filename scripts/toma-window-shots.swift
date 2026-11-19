// SPDX-License-Identifier: GPL-3.0-or-later
// Writes a PNG of each on-screen window of the process with <pid> into <folder> (`scripts/ui-shots.sh`).
// Needs Screen Recording for the app that runs it (the terminal, or the app it runs in).
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = Int32(arguments[1]) else {
    FileHandle.standardError.write("usage: toma-window-shots <pid> <folder> <name>\n".data(using: .utf8)!)
    exit(2)
}
let folder = arguments[2], name = arguments[3]
// Every window that isn't transparent: `.optionOnScreenOnly` and `kCGWindowIsOnscreen` leave out a new app's windows.
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid
    && (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
    guard let number = window[kCGWindowNumber as String] as? Int,
          let dictionary = window[kCGWindowBounds as String] as! CFDictionary?,
          let bounds = CGRect(dictionaryRepresentation: dictionary),
          bounds.width >= 60, bounds.height >= 30 else { continue }
    // The menu bar item and its padding windows are thin strips: left out.
    if bounds.height <= 40, bounds.width > 1000 { continue }
    let path = "\(folder)/\(name)-\(count).png"
    let task = Process()
    task.executableURL = URL(filePath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l", String(number), path]
    try task.run()
    task.waitUntilExit()
    print(path)
    count += 1
}
