// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// Where new recordings go and what they are called: `~/Movies/<app>/<prefix> yyyy-MM-dd HH.mm.ss.toma`,
/// with ` 2`, ` 3`, … added when that name is taken.
public enum ProjectFolder {
    /// `~/Movies/<appName>/`.
    public static func defaultURL(appName: String) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent(appName, isDirectory: true)
    }

    /// `<prefix> yyyy-MM-dd HH.mm.ss`, the date in `timeZone` with Western digits whatever the locale.
    public static func baseName(prefix: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    /// Creates `directory` if needed and a new package in it named after `now`, adding ` 2`, ` 3`, … to
    /// the name while a package of that name exists. Any other failure is thrown.
    public static func createPackage(
        in directory: URL, prefix: String, app: AppInfo, now: Date, timeZone: TimeZone = .current
    ) throws -> ProjectPackage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = baseName(prefix: prefix, date: now, timeZone: timeZone)
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            do {
                return try ProjectPackage.create(in: directory, name: name, app: app, now: now)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                attempt += 1
            }
        }
    }
}
