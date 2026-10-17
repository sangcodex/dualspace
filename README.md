# DualSpace

[中文](README.zh.md)

Create standalone macOS app copies with their own identity and data configuration. After creation, launch the copied `.app` directly from Finder or the Dock. DualSpace can be closed; no manager process, proxy, or background service is required by a copy.

## Run

Double-click `dist/DualSpace.app`. If it has not been built yet, double-click `Launch.command` or run:

```sh
./scripts/build.sh
```

Choose an app in **App library**, or drop a `.app` into the window. Name the instance, create it, then use **Show Copy in Finder** from its actions menu. Drag that app to the Dock for everyday use. Each copy has its own stable identifier and a distinguishable icon.

Instance cards and the menu bar show checking, starting, running, quitting, failed, or missing-copy states. Running copies show their PID; startup failures offer a retry and an explanation. Opening a copy from Finder also updates its status, even with the manager window closed. Process status does not imply that an account is signed in.

Click the sidebar icon beside the page title, or press **Control-Command-S**, to collapse or expand the left sidebar. Navigation remains available as icons, and the app remembers the choice.

Creation and updates copy and sign the application once. Ordinary launches perform no full-bundle signing scan. Ongoing status uses system application events; only a pending launch uses a bounded check while the process registers with macOS.

## How spaces run

- Native sandboxed apps keep their own main executable and use a distinct macOS container.
- WeChat private-home copies keep the native entry point and receive their profile through Launch Services. Their AppEx helpers have separate identities, and the inherited vendor team prefix is cleared to keep Crashpad service names within macOS limits.
- Other native apps use a private home. The small embedded launcher replaces itself with the copied program using `exec`; it does not stay resident.
- Chromium and Electron apps additionally receive a dedicated `--user-data-dir`. Sandboxed Chromium apps keep that profile inside their own container.

Copies contain their own program files and launcher. They do not consult the original app or DualSpace at startup. Rebuilding requires the original app. Rebuilding and renaming retain the instance identity and data path. Removing an instance retains its data and moves its app bundle to the workspace's recoverable `Retired` folder.

Independent processes and separate profiles do not automatically provide a security sandbox. Apps with fixed data paths, shared services, vendor authorization, App Store receipt checks, or web sign-in callbacks may need app-specific support. The interface distinguishes observed startup from unverified account separation. **Universal app compatibility is not claimed.**

## Current validation

The core tests cover failed-signing rollback, identity preservation, concurrent operations, unsafe paths, cancellation and standalone preflight. A real Cocoa probe records its Foundation home and persistent launch count. This validates the mechanism, not every target app.

The official WeChat 4.1.15 private-home copy now runs alongside the installed 4.1.13. A Crashpad service name exceeded macOS's 128-byte buffer, blocking AppEx initialization; the copy also retained the original AppEx helper identities. Both issues are addressed while retaining the existing account directory. The user confirmed that Moments opens for the copied account and works normally. See [verification notes](docs/verification.md) and the [repair design](docs/design/wechat-moments.md). Long-term stability and other WeChat releases remain unverified.

The sandbox probe also opens directly with DualSpace closed and its source app temporarily unavailable. Thirty-two tests pass, including WeChat isolation, translocated process detection, launch handoff and timeout, failure recovery, and window-independent state updates. A real Cocoa probe also passed launch, quit, external events, failure and retry checks. If source signing permissions cannot be read, creation and rebuilding stop and preserve the existing state; retry from the graphical app outside the restricted terminal.

## Local privacy

`.gitignore` excludes local workspaces, profiles, manifests, recovery copies, databases, logs, captures, app bundles, installers, credentials and build output. Public verification notes use redacted paths and instance identifiers. Store raw diagnostics and screenshots under `.local/`.

Before sharing source, run `./scripts/check-privacy.sh` (requires Git and ripgrep). It checks ignore rules, shareable files, and the Git index when present, including files already tracked despite ignore rules. It reports filenames without printing sensitive matches and uploads nothing. This check covers known patterns in current files and index contents, not remote repositories or historical commits. Share development build output only after reviewing it; use `DUALSPACE_STANDARD_STORAGE=1` to avoid embedding the local workspace path.

## Development

macOS 13 or newer and Xcode Command Line Tools are required. Builds are native to the machine's architecture; this session used Apple Silicon and macOS 27.0.1.

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/build-probe.sh
DUALSPACE_PROBE_SANDBOX=1 ./scripts/build-probe.sh
./scripts/cli.sh inspect '/Applications/Google Chrome.app'
./scripts/cli.sh create '/Applications/Google Chrome.app' 'Chrome Work'
./scripts/cli.sh list
```

`scripts/cli.sh` runs the last built CLI. Run `scripts/build.sh` after changing source. `DUALSPACE_HOME` overrides storage. Local builds store copies and profiles under this project's `.local` folder and embed that development workspace in the app. For a normal Application Support build:

```sh
DUALSPACE_STANDARD_STORAGE=1 ./scripts/build.sh
```

The local build is ad-hoc signed, not notarized. It does not change system security settings. Build staging and package caches remain in the project. The build flag `--disable-sandbox` avoids a nested SwiftPM build sandbox; it does not change macOS security settings or the runtime sandbox of a target app.

The [design](docs/design/dualspace.md) explains compatibility decisions and primary references.
