---
description: Ship the current Trio branch to TestFlight — local compile gate, commit, dispatch CI, watch to "finished processing", report the build number. Use for any "ship it / send me a build" request on this repo.
---

# Ship Trio to TestFlight

## Purpose
One reliable loop for getting a change onto Eddie's phone. Encodes the failure modes already hit in practice (overlapping CI runs colliding on build numbers, project-vs-workspace builds failing on driver submodules, Apple processing wedging for hours).

## When to use
Any time a code change on this repo should reach TestFlight.

## Steps
1. **Local compile gate** (never dispatch CI blind). Build the workspace, NOT the project (the driver submodules only resolve via the workspace). Default derived data (custom paths have corrupted before):
   ```
   xcodebuild build -workspace Trio.xcworkspace -scheme Trio \
     -destination 'generic/platform=iOS Simulator' \
     CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE "error: |BUILD SUCCEEDED|BUILD FAILED" | grep -v "var error" | head
   ```
   If watch files changed, also build scheme `"Trio Watch App"` with `-destination 'generic/platform=watchOS Simulator'`.
   May require running with the sandbox disabled (package resolution needs network).
2. **Commit + push** to the working branch (currently `feat/v083-everything`). Never push upstream (`upstream` push is DISABLED — keep it that way).
3. **Check for in-flight CI runs first**: `gh run list --repo edwardmsalem/Trio --workflow "4. Build Trio" --limit 1`. NEVER dispatch while another run is in progress — build numbers auto-increment from latest TestFlight and overlapping runs collide.
4. **Dispatch**: `gh workflow run "4. Build Trio" --repo edwardmsalem/Trio --ref <branch>`.
5. **Watch in a background loop** (poll `gh run view <id> --json status,conclusion` every ~60s). On completion, grep the log for `finished processing the build` to get the exact version/build number.
6. **Wedged-run rule**: if the run sits on "Fastlane upload to TestFlight" for >90 min, it's stuck in Apple processing — cancel it and re-dispatch from branch tip (the replacement picks up everything pushed since).
7. **Report** the build number to Eddie with a 2–4 bullet "what to test" list.

## Expected output
"✅ Build X.Y.Z (NN) is on TestFlight" + test checklist. Total wall time ~25–45 min.
