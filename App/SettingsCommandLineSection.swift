// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Observation
import SwiftUI

/// Settings ▸ General ▸ «Install Command Line Tool» (fases 4 y 5 design §6.2, plan 4b decision 20): a link `toma` to this
/// app's `Contents/Helpers/toma`, in `/usr/local/bin` or `~/.local/bin` (`CommandLineToolInstaller`). Under it, where the
/// link is and, if its folder is not in the shell's `PATH`, how to add it; what kept it from being installed, in its own
/// words.
struct SettingsCommandLineSection: View {
    @State private var model = CommandLineToolModel()

    var body: some View {
        Section {
            LabeledContent {
                Button {
                    model.install()
                } label: {
                    if model.installed != nil {
                        Text("Reinstall Command Line Tool", comment: "A button in Settings: puts the link to the toma command again")
                    } else {
                        Text("Install Command Line Tool", comment: "A button in Settings: puts a link to the toma command where Terminal finds it")
                    }
                }
                .disabled(model.isWorking || !model.hasTool)
            } label: {
                Text("Command Line Tool", comment: "A setting: the toma command, to edit and export projects from Terminal")
                ForEach(model.lines, id: \.self) { line in
                    Text(line)
                }
            }
        }
        .task { await model.refresh() }
    }
}

/// What the section shows: whether this app's `toma` is linked, where, and what the last install said.
@MainActor @Observable private final class CommandLineToolModel {
    private(set) var installed: URL?
    private(set) var hasTool = true
    private(set) var isWorking = false
    /// What went wrong with the last install, or what it found in the way.
    private var problem: String?
    private var inPath = true

    private let installer = CommandLineToolInstaller(
        tool: CommandLineToolInstaller.tool(in: Bundle.main.bundleURL), path: CommandLineToolInstaller.loginPath)

    /// The lines under the row's name.
    var lines: [String] {
        var lines: [String] = []
        if !hasTool {
            lines.append(String(localized: "This build of Toma has no command line tool.", comment: "Under Install Command Line Tool in Settings, in a build without it"))
        } else if let installed {
            lines.append(Self.abbreviated(installed))
            if !inPath {
                let folder = Self.abbreviated(installed.deletingLastPathComponent())
                lines.append(String(localized: "Add \(folder) to your PATH to use it.", comment: "Under Install Command Line Tool in Settings; the folder where the link is, for example ~/.local/bin"))
            }
        } else {
            lines.append(String(localized: "Edit and export projects from Terminal with the toma command.", comment: "Under Install Command Line Tool in Settings, before it is installed"))
        }
        if let problem { lines.append(problem) }
        return lines
    }

    /// Where the link is now, read off the main thread.
    func refresh() async {
        let installer = installer
        let (link, tool, inPath) = await Task.detached {
            let link = installer.installed()
            return (link, FileManager.default.isExecutableFile(atPath: installer.tool.path), link.map { installer.isInPath($0.deletingLastPathComponent()) } ?? true)
        }.value
        installed = link
        hasTool = tool
        self.inPath = inPath
    }

    func install() {
        guard !isWorking else { return }
        isWorking = true
        problem = nil
        let installer = installer
        Task {
            let outcome = await Task.detached { Result { try installer.install() } }.value
            switch outcome {
            case .success(.blocked(let link)):
                problem = String(localized: "Another toma is at \(Self.abbreviated(link)): it was left as it is.", comment: "Under Install Command Line Tool in Settings: a file or a link of something else has the name toma there")
            case .success:
                break
            case let .failure(error):
                problem = String(localized: "It could not be installed: \(error.localizedDescription)", comment: "Under Install Command Line Tool in Settings; the system's reason follows")
            }
            await refresh()
            isWorking = false
        }
    }

    /// `url`'s path with the home folder as `~`.
    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
