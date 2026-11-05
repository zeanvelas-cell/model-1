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

How to check them is in the [README](README.md#check-your-download-optional).

## Known limitations (we list them so you don't have to find them)
- **The app is not signed by Apple.** It is installed by signing it yourself with a sideloading tool. iOS will show it as a developer app, not an App Store app.
- **Stream key storage.** The key is stored in the Keychain and also in the app's local settings. We are working on a fix that does not depend on entitlements that sideloading tools often strip.
- **Not independently audited.** The scorecard and badges in this repository are automatic or self-assessed. They are not a security audit.
