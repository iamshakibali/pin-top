# Building Pin Top

Three scripts, one entry point each. No Xcode project required.

## `run.sh` — dev build + launch

```bash
./run.sh
```

Builds the debug binary with SwiftPM, bundles it into `PinTop.app` in place (rewriting the Mach-O + Info.plist keeps the TCC designator stable so permission grants stick), signs it, and opens it.

Use this during development.

## `setup-signing.sh` — stable signing identity (one-time)

```bash
./setup-signing.sh
```

Creates a self-signed **"Pin Top Local Signing"** identity in your login keychain. Once it exists, `run.sh` and `release.sh` sign with it instead of ad-hoc, so macOS Screen Recording / Accessibility grants persist across rebuilds instead of resetting each time.

Run once per machine. Safe to re-run (no-ops if the identity exists).

> After importing, the next `codesign` may prompt for your keychain password. Click **"Always Allow"** (or run `security set-key-partition-list`) so it stops asking.

## `release.sh` — distribution build

```bash
./release.sh
```

Builds an optimized release binary (`swift build -c release`), strips it, bundles + signs `PinTop.app`, verifies the signature, and zips the app into `dist/PinTop-<version>.zip` — ready to upload to [GitHub Releases](https://github.com/iamshakibali/window-pin/releases).

The version is read from `CFBundleShortVersionString` in `Resources/Info.plist`. Bump it there before tagging a release.

## Creating a release

```bash
# 1. Bump version in Resources/Info.plist and the CHANGELOG.
# 2. Build the distributable.
./release.sh
# 3. Commit, tag, push.
git tag v0.1.0
git push origin main --tags
# 4. Create a release and upload dist/PinTop-0.1.0.zip.
```

## Requirements

- Swift 5.9+ (`swift build`)
- macOS 14+
- `openssl` (ships with macOS / XcodeCommandLine tools) for `setup-signing.sh`