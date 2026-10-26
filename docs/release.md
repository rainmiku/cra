# Releasing Cra

Goal: a build that installs like any other Mac app. Download the DMG, drag Cra to
Applications, open it. No right-click, no warnings. That needs three things on top of
the plain build: a Developer ID signature with the hardened runtime, Apple's
notarization ticket stapled to the app and the DMG, and a packaged download.
Everything is scripted; the only manual part is obtaining the certificate once.

## One-time setup

1. **Apple Developer Program** membership for the account that will sign.
2. **Developer ID Application certificate.** In Xcode → Settings → Accounts → Manage
   Certificates, add "Developer ID Application". Export it from Keychain Access as a
   `.p12` with a password. Note the identity string, for example
   `Developer ID Application: Victor Kildahl (ABCDE12345)`:
   `security find-identity -v -p codesigning`.
3. **Notarization credentials.** Create an app-specific password at appleid.apple.com.
   Locally you can store it once: `xcrun notarytool store-credentials cra --apple-id
   you@example.com --team-id ABCDE12345` and then set `NOTARY_KEYCHAIN_PROFILE=cra`.
4. **GitHub secrets** on `VictorKildahl/cra` (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `MACOS_CERTIFICATE_PASSWORD` | the `.p12` password |
   | `MACOS_SIGN_IDENTITY` | the identity string from step 2 |
   | `APPLE_ID` | the Apple ID email |
   | `APPLE_TEAM_ID` | the 10-character team id |
   | `APPLE_APP_PASSWORD` | the app-specific password |

5. **In-app updates (Sparkle).** Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
   once (after any `swift build`); it keeps the private key in your login Keychain.
   Store `generate_keys -x key.txt` contents as the secret `SPARKLE_PRIVATE_KEY`, then
   delete the file, and the public key (`generate_keys -p`) as the repository
   *variable* `SPARKLE_PUBLIC_KEY`. Release builds then check
   `releases/latest/download/appcast.xml` every 6 hours, download updates in the
   background and install them on quit. Losing the private key strands every
   installed copy, so back it up.

Until these exist the Release workflow still runs: it publishes an ad-hoc build as a
regular release (pre-releases are invisible to `releases/latest`) with the install
steps in `.github/release-notes-unsigned.md`.

## Installing unsigned builds

Gatekeeper only checks files carrying the quarantine flag, which browsers set and curl
does not. So the friction-free path for an ad-hoc build is `scripts/install.sh`, run as

```sh
curl -fsSL https://raw.githubusercontent.com/VictorKildahl/cra/main/scripts/install.sh | bash
```

It downloads `releases/latest/download/Cra.zip`, replaces the app in `/Applications`
(or `~/Applications`), quitting a running Cra first, and opens it. Rerunning it updates.

The DMG path needs one manual approval: open Cra, click Done on the "could not verify"
dialog, then System Settings → Privacy & Security → Open Anyway. Right-click → Open no
longer bypasses Gatekeeper since macOS 15. The README, release notes and the website's
download page all carry both paths; keep them in step.

## Cutting a release

```sh
# 1. Add the release to the website's src/content/releases.ts and bump CRA_VERSION defaults if needed.
# 2. Tag and push. The Release workflow builds, signs, notarizes, packages and publishes.
git tag v0.1.0
git push origin v0.1.0
```

Artifacts land on the GitHub release: `Cra.dmg`, `Cra.zip`, `SHA256SUMS.txt`. The names
carry no version so `releases/latest/download/Cra.dmg` always resolves; the website's
download button and `scripts/install.sh` rely on that.

## Locally

```sh
CRA_VERSION=0.1.0 \
CRA_SIGN_IDENTITY="Developer ID Application: Victor Kildahl (ABCDE12345)" \
NOTARY_KEYCHAIN_PROFILE=cra \
scripts/release.sh
```

`scripts/release.sh` runs `build.sh` (sign, innermost first, with the CEF entitlements),
notarizes and staples the app, runs `package.sh` (zip, DMG with an Applications link,
checksums), then notarizes and staples the DMG and checks it with `spctl`.
Without `CRA_SIGN_IDENTITY` it produces an ad-hoc build and skips notarization.

## CEF updates

`.github/workflows/cef-update.yml` checks the CEF build index every 4 hours. When a
newer stable macosarm64 build exists, it bumps the version and SHA-1 pin in
`scripts/fetch-cef.sh`, builds, runs `scripts/smoke-test.sh` and opens a pull request
from `cef/<version>`. If the build or smoke test fails (a new Chromium major can need
fixes in `Sources/CraCEF`), the pull request opens as a draft and the run fails.
Merge, then tag a release. Run it by hand from the Actions tab, optionally with a
specific version.

It needs Settings → Actions → General → "Allow GitHub Actions to create and approve
pull requests". Pull requests opened with the default token do not trigger CI; add a
fine-grained token with contents and pull-request write access as the secret
`CEF_BOT_TOKEN` if you want CI on them.

## What the signing covers

Order matters because each signature seals what is inside it:

1. every `.dylib` in `Chromium Embedded Framework.framework/Libraries`
2. the framework itself
3. Sparkle's XPC services, `Autoupdate`, `Updater.app`, then `Sparkle.framework`
4. the five helper apps, each with `resources/CraHelper.entitlements`
5. `Cra.app` with `resources/Cra.entitlements`

The entitlements are the hardened-runtime exceptions Chromium needs (JIT, unsigned
executable memory, library validation off, dyld environment variables), plus camera,
microphone and location so sites can ask for them.

## Later

- **Homebrew.** A cask (`brew install --cask cra`) pointing at the DMG and
  `SHA256SUMS.txt`.
- **Intel.** The CEF fetch pins `macosarm64`; a universal build needs both CEF
  distributions and `lipo`.
