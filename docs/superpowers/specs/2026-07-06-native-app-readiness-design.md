# Native App Readiness (WS8) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "native app readiness").
**Author:** Claude (pairing with Jarrod)

The app is a single Flutter codebase but currently only has a `web/` target — no
`android`/`ios`/`windows`/`macos`/`linux` folders, no launcher icon, no splash.
This workstream makes it a real native app buildable for the iOS/Android stores
and desktop, per the product goal ([[product-goal]]).

## Reality of this environment (shapes scope)

- Host: **Windows** (Flutter 3.44.4). Buildable here: **web** (✓), **Windows
  desktop** and **Android** *if* toolchain gaps are closed. **iOS/macOS cannot
  be built on Windows** (need a Mac + Xcode); **Linux** needs a Linux host.
- Toolchain gaps that are the **user's** to resolve: Android `cmdline-tools`
  missing + licenses unaccepted; VS Build Tools missing the Windows 10 SDK.
- Store submission — Apple/Google developer accounts, signing certificates,
  provisioning, store listings, and uploads — is **entirely user-owned**
  (Claude will not and cannot create accounts, sign, or upload). These are
  documented, not automated.

So WS8 delivers: **scaffolding + configuration + icon/splash + build
verification where the toolchain allows + a precise SHIPPING checklist**. It
does NOT deliver signed store binaries (blocked on user-owned accounts/toolchain).

## App identity (defaults — changeable before first publish)

- **Display name:** `Soft PLC Simulator` (Android label, iOS `CFBundleDisplayName`,
  desktop window title, web title).
- **Bundle / application ID:** `com.jarrodfranz.softplcsimulator` (Android
  `applicationId`/`namespace`, iOS/macOS bundle identifier). Reverse-domain;
  hard to change post-publish — flagged for user confirmation.
- **Version:** keep `0.1.0+1` for now (semantic; `+1` build number).
- **Package (Dart):** `soft_plc_mobile` unchanged.

## Work

1. **Scaffold platforms:** `flutter create --platforms=android,ios,windows,macos,linux
   --org com.jarrodfranz .` in `mobile/` — generates the native runner folders
   WITHOUT touching `lib/`. Verify `lib/`, tests, and `pubspec` deps survive and
   the suite still passes.
2. **App identity:** set the display name across Android manifest, iOS/macOS
   `Info.plist`/`AppInfo.xcconfig`, the desktop runners' window title, and the
   web `manifest.json`/`index.html`. Confirm bundle IDs applied by `--org`.
3. **Launcher icon + splash:** add a generated 1024×1024 source icon (a clean,
   neutral mark on the app's dark theme — no third-party/reference-editor
   branding) produced by a small pure-Dart script using `package:image`; wire
   `flutter_launcher_icons` and `flutter_native_splash` (dev deps) and generate
   platform icons/splash. Dark splash background matching the theme
   (`#0F172A`).
4. **Platform config:**
   - **Android:** `minSdkVersion` sane (flutter default is fine); ensure
     `file_picker`/`share_plus` work (they declare their own manifest bits;
     confirm no extra runtime permission needed for the SAF-based pickers —
     avoid broad storage permissions). Kotlin/gradle build settles.
   - **iOS:** deployment target per plugins; `Info.plist` display name; document
     that a `.splc.json` document type / share is optional polish (deferred).
   - **Desktop (windows/macos/linux):** set the window title and a sensible
     **minimum window size** so the responsive layout has room (e.g. 640×480+);
     desktop uses the ≥840 multi-pane layout at normal sizes.
5. **Verify:** `flutter analyze` (0) · full `flutter test` (unchanged, all pass)
   · `flutter build web --release` (✓) · attempt `flutter build windows
   --release` and `flutter build apk --release` — if a toolchain gap blocks
   them, capture the exact error and document the user fix rather than treating
   it as a code failure. iOS/macOS/Linux: configured, build on that OS.
6. **`SHIPPING.md`:** a precise, honest checklist of the user-owned steps —
   Android (accept licenses, install cmdline-tools, keystore, Play Console,
   `flutter build appbundle`), iOS (Mac + Xcode, Apple Developer account,
   signing, `flutter build ipa`, App Store Connect), desktop (Windows 10 SDK for
   Windows build; macOS/Linux hosts), and where app identity/icon live for
   changes.

## Testing / acceptance

- `lib/` unchanged; **all existing tests still pass** (scaffolding must not break
  the app or suite); `flutter analyze` zero.
- Web build succeeds; at least one native build (Windows or Android) either
  succeeds OR its blocker is a documented toolchain/user gap (not a code defect).
- Launcher icons + splash generated for the scaffolded platforms.
- `SHIPPING.md` present and accurate; app identity defaults applied consistently.

## Global constraints

No third-party/reference-editor branding in the app name, icon, identifiers, or
copy. Dark theme. `flutter analyze` zero. Engines/UI logic unchanged — this is
platform scaffolding + config only. Secrets (keystores, signing) are NEVER
committed; `SHIPPING.md` documents them as user-managed via environment/secure
storage.

## Out of scope (deferred / user-owned)

- Creating developer accounts, signing certificates/keystores, provisioning
  profiles; any store upload/listing.
- Installing the user's local toolchain gaps (Android cmdline-tools/licenses,
  Windows 10 SDK, Xcode).
- A professionally designed icon (a clean placeholder is provided; replace
  before launch).
- `.splc.json` as a registered document type / deep-link handling; push
  notifications; app-store screenshots.
- App↔Rust bridge and protocol adapters (separate track).
