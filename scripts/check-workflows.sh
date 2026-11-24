#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks the GitHub workflows: each parses as YAML, starts with the SPDX header and sets `permissions:`, every `uses:` names a
# full 40-hex commit SHA (a tag can be moved to other code), and every actions/checkout step has
# `persist-credentials: false` (otherwise the job's token stays in .git/config for every later step).
#   bash scripts/check-workflows.sh
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
problem() {
  echo "✘ $1"
  failures=$((failures + 1))
}

for workflow in .github/workflows/*.yml; do
  # It parses as YAML: a step's name with ": " in it needs quotes, or GitHub starts no job at all.
  ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$workflow" 2>/dev/null || problem "$workflow: not valid YAML"
  [[ $(head -1 "$workflow") == "# SPDX-License-Identifier: GPL-3.0-or-later" ]] || problem "$workflow: no SPDX header on its first line"
  grep -qE '^permissions:' "$workflow" || problem "$workflow: no top-level permissions"
  while IFS= read -r line; do
    problem "$workflow: not pinned to a commit SHA: ${line#"${line%%[![:space:]]*}"}"
  done < <(grep -E '^[[:space:]-]*uses:' "$workflow" | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' || true)
  # Each checkout step, up to the next step, must say persist-credentials: false.
  unpersisted=$(awk '
    /^[[:space:]]*-[[:space:]]/ { if (checkout && !safe) print step; checkout = 0; safe = 0; step = NR }
    /uses:[[:space:]]*actions\/checkout@/ { checkout = 1 }
    /persist-credentials:[[:space:]]*false/ { safe = 1 }
    END { if (checkout && !safe) print step }
  ' "$workflow")
  for line in $unpersisted; do problem "$workflow:$line: actions/checkout without persist-credentials: false"; done
done

if ((failures > 0)); then
  echo "check-workflows: $failures problems" >&2
  exit 1
fi
echo "check-workflows: $(ls .github/workflows/*.yml | wc -l | tr -d ' ') workflows, every action pinned, no persisted credentials"
