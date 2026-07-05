# Shipping Guide — Soft PLC Simulator

How to build and publish the app to the iOS/Android stores and desktop. The
codebase is a **single Flutter app** targeting Android, iOS, Windows, macOS,
Linux, and web from one source tree (`mobile/`).

> **Not a safety product.** This is a simulator/learning tool. Do not present it
> as a safety-certified PLC (SIL/IEC 61508). Keep the simulator framing in the
> store listing.

## What is already done (in-repo)

- **All platform targets scaffolded:** `android/ ios/ windows/ macos/ linux/ web/`.
- **App identity** applied everywhere user-facing:
  - Display name: **Soft PLC Simulator**
  - Bundle / application ID: **`com.jarrodfranz.softplcsimulator`**
    (Android `applicationId`, iOS/macOS `PRODUCT_BUNDLE_IDENTIFIER`)
  - Version: `0.1.0+1` (in `mobile/pubspec.yaml` — `version: <semver>+<build>`)
- **Launcher icon + splash** generated for every platform. Source art is
  produced by `mobile/tool/generate_icon.dart`; regenerate with:
  ```
  cd mobile
  dart run tool/generate_icon.dart          # rebuild assets/icon/*.png
  dart run flutter_launcher_icons            # regenerate platform icons
  dart run flutter_native_splash:create      # regenerate splash
  ```
- **Web** builds today: `cd mobile && flutter build web --release`.
- 251 tests pass; `flutter analyze` is clean.

### To change the app name or bundle ID
Bundle IDs are painful to change after first publish — decide before uploading.
- Name: `android/app/src/main/AndroidManifest.xml` (`android:label`),
  `ios/Runner/Info.plist` (`CFBundleDisplayName`),
  `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_NAME`), the desktop runner
  window titles, `web/manifest.json` + `web/index.html`, and the `MaterialApp`
  `title:` in `mobile/lib/main.dart`.
- ID: `android/app/build.gradle.kts` (`applicationId`), the iOS/macOS
  `PRODUCT_BUNDLE_IDENTIFIER`.

## Per-platform build — prerequisites and commands

These require local toolchain/OS setup and (for the stores) developer accounts,
signing keys, and uploads. **Claude cannot create accounts, generate signing
certificates, or upload to stores — those steps are yours.** Never commit
keystores, certificates, or provisioning profiles.

### Web (works now)
```
cd mobile && flutter build web --release        # output: build/web
```
Host the `build/web` folder on any static host.

### Android → Google Play
1. Install the **Android SDK command-line tools** (Android Studio → SDK Manager →
   SDK Tools → "Android SDK Command-line Tools"), then accept licenses:
   ```
   flutter doctor --android-licenses
   ```
   (This environment was missing `cmdline-tools`, so `sdkmanager`/licenses were
   unavailable.)
2. If your network intercepts TLS (corporate proxy), Gradle may fail with
   `unable to find valid certification path` — add your proxy's CA to the JDK
   truststore or configure `~/.gradle/gradle.properties` proxy settings. (Seen in
   this environment.)
3. Create an **upload keystore** (kept OUT of git) and reference it via
   `android/key.properties` + signing config in `android/app/build.gradle.kts`
   (see flutter.dev/deployment/android). Store the keystore + passwords in a
   secrets manager / env, never in the repo.
4. Build the app bundle and upload:
   ```
   flutter build appbundle --release            # build/app/outputs/bundle/release/app-release.aab
   ```
   Upload the `.aab` in the **Google Play Console** (one-time $25 developer
   account). Provide listing, screenshots, and a privacy policy.

### iOS → App Store (requires a Mac)
1. On **macOS with Xcode**; an **Apple Developer account** ($99/yr).
2. `cd mobile && flutter build ipa --release` (or open
   `ios/Runner.xcworkspace` in Xcode, select your signing Team, Archive).
3. Upload via Xcode Organizer / Transporter to **App Store Connect**; fill the
   listing (screenshots, privacy). iOS cannot be built on Windows/Linux.

### macOS → Mac App Store / notarized DMG (requires a Mac)
```
cd mobile && flutter build macos --release
```
Sign + notarize with your Apple Developer account for distribution outside the
store, or submit to the Mac App Store.

### Windows (desktop)
1. **Enable Developer Mode** (`start ms-settings:developers`) — required for the
   symlink support Flutter uses when building a plugin-based app on Windows.
   (This blocked the build in the dev environment.)
2. Install the **Windows 10/11 SDK** component in Visual Studio / Build Tools
   (doctor reported it missing).
3. Build:
   ```
   cd mobile && flutter build windows --release  # build/windows/x64/runner/Release
   ```
   Package with MSIX (`msix` package) for the Microsoft Store, or ship the
   Release folder / an installer.

### Linux (desktop)
On a Linux host with the GTK/clang/ninja toolchain:
```
cd mobile && flutter build linux --release
```
Package as a Flatpak/Snap/AppImage/.deb as desired.

## Dependencies that touch native platforms
`shared_preferences` (persistence), `file_picker` + `share_plus` (project
export/import). All are cross-platform; they pull in per-platform plugin code
that the scaffolded runners already register. No extra runtime storage
permissions are required for the SAF/document-picker flows used here.

## Not in scope of this readiness pass (do before/at launch)
- Developer accounts, signing certificates/keystores, provisioning, store
  uploads and listings (screenshots, description, privacy policy).
- Installing local toolchain gaps (Android cmdline-tools/licenses, Windows 10
  SDK + Developer Mode, Xcode on a Mac).
- A professionally designed icon (current mark is a clean, brand-free
  placeholder — replace `mobile/assets/icon/app_icon*.png` and regenerate).
- Registering `.splc.json` as a document type / deep links; push notifications.
- A hard **minimum desktop window size** is intentionally not enforced: the
  responsive layout (WS5) collapses to the compact drawer UI when a desktop
  window is shrunk, so the app stays usable at any size. Add
  `WM_GETMINMAXINFO` (Windows) / `gtk_widget_set_size_request` (Linux) if you
  want a hard floor.
