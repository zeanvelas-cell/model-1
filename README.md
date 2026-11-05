# PulseLite

A free, open-source iPhone game broadcaster. Stream your screen (games like CODM) to **YouTube, Twitch or Kick** with overlays, mic mixing, 16:9 or vertical Shorts layouts and a Privacy Shield.

**No ads. No accounts. No tracking.** See [PRIVACY.md](PRIVACY.md).

## Download
Get the latest `PulseLite-Glass-Broadcaster.ipa` from the **[Releases](../../releases)** page.

The IPA is **unsigned**. You install it by signing it with your own Apple ID using a sideloading tool on a Windows or Mac computer (for example Sideloadly or AltStore). Apps signed with a free Apple ID expire after about 7 days and need to be re-signed. Some tools can do this automatically, so check your tool's documentation.

Sideloading tools often remove "App Groups". PulseLite still works: the broadcast setup sheet will ask for your stream key.

## Check your download (optional)
Every release is built by GitHub from the public code in this repository, so you can verify the file was not changed.

**1. Checksum.** Compare the result with `SHA256SUMS.txt` from the release.
- Windows (Command Prompt): `certutil -hashfile PulseLite-Glass-Broadcaster.ipa SHA256`
- Mac: `shasum -a 256 PulseLite-Glass-Broadcaster.ipa`

**2. Build proof.** With the [GitHub CLI](https://cli.github.com/) installed:

```
gh attestation verify PulseLite-Glass-Broadcaster.ipa --repo zeanvelas-cell/model-1
```

A successful result shows which commit and workflow built the file.

## Privacy and security
- [PRIVACY.md](PRIVACY.md): what the app does and does not do with your data.
- [SECURITY.md](SECURITY.md): how to report a problem, and our known limitations.

## Build it yourself
The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` and built by the workflow in `.github/workflows`. Building on your own machine needs macOS and Xcode.

## License
[MIT](LICENSE). Not affiliated with Apple, YouTube, Twitch or Kick.
