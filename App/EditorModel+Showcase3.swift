// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import Foundation

/// The screens of phase 3 for `-TomaShowcase editor <package>`: each feature looks at its own `TOMA_SHOWCASE_P3_<NAME>`
/// variables in its own file (`Showcase+Annotations`, `Showcase+CalmZoom`, `Showcase+Audio`, `Showcase+Takes`), after the
/// showcase of phases 1 and 2 has set the editor up.
extension EditorModel {
    func showcasePhase3(_ environment: [String: String]) async {
        await showcaseAnnotations(environment)
        await showcaseCalmZoom(environment)
        await showcaseAudio(environment)
        await showcaseTakes(environment)
    }
}
#endif
