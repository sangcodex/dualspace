# DualSpace

[中文](README.zh.md)

A macOS tool for running **two or more copies of an app**. WeChat and QQ have dedicated compatibility adaptations, with support for other compatible apps too. Each copy can launch directly from Finder or the Dock, even after you quit DualSpace.

## How to use

Requires **Apple Silicon (M-series), macOS 13 or later**.

1. Open the downloaded DMG and drag **DualSpace.app** into **Applications**.
2. Open DualSpace and select an installed app, or drop a `.app` into the window.
3. Name and create a copy, then launch it and sign in as needed.
4. To run more copies, select the same original app and repeat with different names.

Instance cards show startup and running status. Use **Show Copy in Finder** to locate a copy and add it to the Dock. The left sidebar can be collapsed with **Control-Command-S**.

The app has not been notarized by Apple. If macOS blocks it, confirm that you trust the source, then allow it in **System Settings → Privacy & Security**.

## Compatibility

- **WeChat:** dedicated adaptation; Moments has been confirmed working for the copied account in WeChat 4.1.15.
- **QQ:** dedicated adaptation; QQ 7.0.2 has been verified running alongside the original with a separate process, window and data directory. Account login has not yet been verified.
- **Other apps:** general support for native, Electron and Chromium apps; Chrome has also been verified running alongside its original. Compatibility varies by app and version.

The installer contains only DualSpace, with no third-party apps or account data. Install the original apps separately.

## Disclaimer

- This project is provided **solely for learning, research and technical exchange**. Follow applicable laws, software licenses and platform rules. Do not use it for unlawful activities or to infringe others' rights.
- This is an independent project, unaffiliated with the developers of WeChat, QQ or other supported apps. Their names and trademarks belong to their respective owners.
- The software is provided as is, without guarantees of compatibility, stability or account safety. Back up important data before use. To the extent permitted by law, the authors accept no liability for losses arising from its use or misuse.
