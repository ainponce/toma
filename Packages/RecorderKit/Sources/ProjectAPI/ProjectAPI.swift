// SPDX-License-Identifier: GPL-3.0-or-later

/// The project API (phase 4, milestone 4b): what the `toma` command and the control socket offer over a project. It never
/// imports AppKit, so a command line tool and the app share it.
public enum ProjectAPI {
    /// The version of the API, which the `toma` command prints.
    public static let version = "1.0"
}
