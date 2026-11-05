# Security

Artifloam removes files and can hold powerful permissions, so security reports are very welcome.

## Reporting a vulnerability

Please **don't open a public issue**. Use [private vulnerability reporting](../../security/advisories/new) on this repository, and include:

- what you found and which version it affects
- steps to reproduce it
- what an attacker could do with it

## Supported versions

Security fixes go into the latest release.

## How official builds are protected

- Builds are signed with a Developer ID and notarized by Apple.
- Updates install only when you click. An update replaces the app only after all of these pass; otherwise the current app stays untouched:
  - it's downloaded over HTTPS from the official site
  - its version, link and hash are signed by Artifloam's update key
  - the download matches that signed hash
  - the app inside is signed by the same developer and passes Apple's notarization check
  - it's the version the signed notice promised
