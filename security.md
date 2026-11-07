# Security

## Reporting a problem
Please report security problems **privately**, not in a public issue.

1. Open the **Security** tab of this repository.
2. Click **Report a vulnerability**.

If you don't see that button, open a public issue titled "Security contact request" **without any details**, and the maintainer will arrange a private way to talk.

## Supported versions
Only the latest release is supported. Please update before reporting.

## How downloads can be verified
Every release is built by GitHub from the public source code (no one builds it on a personal computer). Each release includes:
- `SHA256SUMS.txt`: the checksum of the file.
- A signed **build attestation**: cryptographic proof of which commit and which workflow produced the file.

How to check them is in the [README](https://www.google.com/search?q=README.md%23check-your-download-optional).

## Known limitations (we list them so you don't have to find them)
- **The app is not signed by Apple.** It is installed by signing it yourself with a sideloading tool. iOS will show it as a developer app, not an App Store app.
- **Stream key storage.** Free Apple ID sideloaders do not support the `keychain-access-groups` entitlement, so Keychain items written by the main app cannot be read by the ReplayKit broadcast extensions. Instead of writing stream keys into `UserDefaults` JSON, PulseLite stores them in a dedicated file (`pulse_stream_key_vault_v1.json`) in the shared App Group container (or `Library/Application Support` when App Groups are absent). This file relies on iOS Data Protection (`completeFileProtectionUntilFirstUserAuthentication`, device encryption at rest) and is excluded from backups (`isExcludedFromBackup = true`). We do not add a custom encryption layer whose key lives next to the file because that would not add real protection. If your sideloader strips the App Groups entitlement, the app and its broadcast extensions cannot share files, so you must enter your stream key in the Broadcast Setup sheet every time you go live.
- **Not independently audited.** The scorecard and badges in this repository are automatic or self-assessed. They are not a security audit.
