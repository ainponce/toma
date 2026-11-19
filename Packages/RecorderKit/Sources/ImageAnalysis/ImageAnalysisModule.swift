// SPDX-License-Identifier: GPL-3.0-or-later

/// Image analysis (design of phase 2, §6.1, §6.2, §7.2 and §10): with Vision, the person masks and the face tracks of
/// the camera's segments and the search for sensitive data on the screen's frames, read with `Render`'s readers.
///
/// An engine of the analysis queue: it is handed the files it reads and writes and reports its progress, and knows
/// nothing of the project's caches or the queue (`ProjectJobs` runs it and names its files). Never called from the
/// render or the mix, which read what it left in the caches. Empty in phase 2's base; milestones 2b and 2c fill it.
enum ImageAnalysisModule {}
