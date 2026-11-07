# Privacy

PulseLite is free and open source. It has no ads, no accounts and no tracking.

**Last checked against the source code: 2026-11-06.** You don't have to take our word for it: the whole app is in this repository.

## What PulseLite does NOT do
- It does not collect, send or sell any personal data.
- It contains no analytics, advertising or crash-reporting code.
- It does not run any servers. Nothing you do is sent to the developer.

## The only network connection
When you go live, PulseLite sends your video, audio and stream key to **the streaming server you chose** (YouTube by default, or Twitch, Kick or any RTMP/RTMPS address you enter). That is how streaming works, and it is the only network connection the app's own code makes.

## What is stored on your device
- Your settings, your stream key(s), and any overlay images you pick.
- An optional local recording (MP4). This is **off by default**.

Nothing stored by PulseLite leaves your device, except what you stream to the server you chose.

## Permissions
- **Screen broadcast:** uses Apple's built-in screen broadcast. You start it yourself and iOS shows when it is active. The Privacy Shield option hides the screen from the stream.
- **Microphone:** used only if you turn on mic commentary. iOS asks you first.

## Third-party code
Streaming uses the open-source [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) library, pinned to an exact version in `project.yml`.

## Known limitation
Because sideloading tools do not support shared Keychain access groups between the main app and its broadcast extensions, your stream key is stored in a local key vault file (`pulse_stream_key_vault_v1.json`) rather than the Keychain or plain `UserDefaults` settings. This file is protected by iOS Data Protection (`completeFileProtectionUntilFirstUserAuthentication`, meaning iOS encrypts it on disk until first unlock after reboot) and is excluded from device backups (`isExcludedFromBackup = true`). If your sideloader removes the App Groups entitlement, the main app and broadcast extensions cannot share storage, so you will need to enter your stream key in the Broadcast Setup sheet each time you go live. You can remove a single key or use **Flush All Keys** in the Accounts screen at any time. See [SECURITY.md](SECURITY.md).

PulseLite is not affiliated with Apple, YouTube, Twitch or Kick.

## Questions
Open an issue in this repository.
