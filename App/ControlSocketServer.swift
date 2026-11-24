// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectAPI
import os

/// The app's control socket (fases 4 y 5 design §6.4): `~/Library/Application Support/dev.toma.Toma/control.sock`, of mode
/// `0600` in a folder of `0700`, where `toma` and the MCP server ask the app to make the changes of a project it has open.
/// A request is answered by the editor of the package it names (found among `editors` by its folder's identity, whatever
/// path names it, and wherever the package is now), on the main actor; no editor of it that can edit, not handled.
/// Another copy of Toma already listening keeps the socket: this one then does without.
@MainActor final class ControlSocketServer {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "ControlSocket")

    private let editors: @MainActor () -> [EditorModel]
    private var server: ControlServer?

    /// `editors`: the app's open editors (`AppDelegate.editors`).
    init(editors: @escaping @MainActor () -> [EditorModel]) {
        self.editors = editors
    }

    /// The editor of the package `id` names that can change it: open (not closing) and editable, its package that folder.
    func editor(of id: ControlPackageID) -> EditorModel? {
        editors().first { model in
            !model.closed && model.canEdit && ControlPackageID(url: model.currentLocation) == id
        }
    }

    /// Listens, in the socket's folder of `0700` (made, or set so, if it is a folder of the user's; anything else there and
    /// it does without). Says in the log why it cannot.
    func start() {
        guard server == nil else { return }
        let path = ControlServer.defaultPath
        guard Self.prepareFolder(path.deletingLastPathComponent()) else { return }
        let server = ControlServer(path: path) { [weak self] request in
            guard request.op != .ping else { return .done }
            // The path the client gave is looked at off the main actor: a volume that hangs never holds the interface.
            let package = request.package
            let found = await Task.detached { () -> Result<ControlPackageID, APIError> in
                do throws(APIError) {
                    return .success(try ControlHandling.packageID(package))
                } catch {
                    return .failure(error)
                }
            }.value
            switch found {
            case let .success(id): return await self?.answer(request, package: id) ?? .notHandled
            case let .failure(error): return .refused(error)
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Self.logger.notice("The control socket is not listened on: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops listening; the socket goes if it is still this app's.
    func stop() {
        server?.stop()
        server = nil
    }

    private func answer(_ request: ControlRequest, package id: ControlPackageID) async -> ControlResponse {
        guard let model = editor(of: id) else { return .notHandled }
        return await model.control(request)
    }

    /// `folder` as the socket's: made with `0700`, or a folder of this user's (never a link) set to `0700`. `false`, said
    /// in the log, otherwise.
    private static func prepareFolder(_ folder: URL) -> Bool {
        if mkdir(folder.path, 0o700) == 0 { return true }
        guard errno == EEXIST else {
            logger.error("Cannot make \(folder.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            logger.error("\(folder.path, privacy: .public) is not a folder of this user: the control socket is not listened on")
            return false
        }
        guard info.st_mode & 0o777 != 0o700 else { return true }
        guard chmod(folder.path, 0o700) == 0 else {
            logger.error("Cannot set \(folder.path, privacy: .public) to 0700: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }
        return true
    }
}
