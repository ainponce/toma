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

    /// Listens, the socket's folder made with `0700` if it is not there. Says in the log why it cannot.
    func start() {
        guard server == nil else { return }
        let path = ControlServer.defaultPath
        let folder = path.deletingLastPathComponent()
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST {
            Self.logger.error("Cannot make \(folder.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let server = ControlServer(path: path) { [weak self] request in
            await self?.answer(request) ?? .notHandled
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

    private func answer(_ request: ControlRequest) async -> ControlResponse {
        guard request.op != .ping else { return .done }
        let id: ControlPackageID
        do throws(APIError) {
            id = try ControlHandling.packageID(request.package)
        } catch {
            return .refused(error)
        }
        guard let model = editor(of: id) else { return .notHandled }
        return await model.control(request)
    }
}
