#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prints the fingerprint of the system the golden files of milestone 1b are recorded on (plan decision 3), one line
# each: the macOS version and build, the two lines of `xcodebuild -version` and the GPU model. Their bytes depend on
# the GPU, the system's Metal compiler and VideoToolbox: `make golden` compares this with the VERSION file next to
# them before it runs, and `make golden-record` writes it there.
set -euo pipefail

sw_vers -productVersion
sw_vers -buildVersion
xcodebuild -version
system_profiler SPDisplaysDataType | sed -n 's/^[[:space:]]*\(Chipset Model:.*\)$/\1/p'
