# Mobile Polish — Haptics + Native Readiness (Phase 7 remainder / WS27) Design

**Date:** 2026-07-09
**Status:** Approved by user (chat, 2026-07-09): both **haptic feedback** and **native mobile readiness**; haptics on **pushbutton / momentary / toggle** operator controls with a global enable toggle (default on). Signing + store submission are the user's (credentials/accounts I can't handle); this workstream does all config, permissions, and docs.
**Builds on:** Phase 7's shipped responsive layout, editor polish, and undo/redo. Completes Phase 7's two remaining ⏳ items (haptics; native packaging readiness). The four in-app protocol hosts (OPC UA/Modbus/MQTT/DNP3) already shipped — this makes them actually usable on a real phone.

## Motivation

The app is meant to run **on a phone as the PLC**, but two gaps block that:
1. **No haptic feedback** — a plant operator tapping an HMI pushbutton on glass gets no tactile confirmation.
2. **Missing on-device network permissions** — iOS 14+ **silently blocks** an app from binding LAN server sockets (or reaching a LAN broker) without the **Local Network** privacy permission, so the protocol hosts would not work on iPhone/iPad as shipped; the Android release manifest lacks the `INTERNET` permission needed to open sockets. Launcher icons, splash, adaptive icons, bundle id (`com.jarrodfranz.softplcsimulator`), and app name ("Soft PLC Simulator") are ALREADY configured — this workstream fills the functional gaps, not the cosmetic ones.

## Scope

**In (v1):**

### A. Haptic feedback
- A small app-level setting `hapticsEnabled` (default **true**), persisted via `SharedPreferences` (there is no central settings store today — add a minimal one), exposed through a **Settings** entry (an item in the workspace app-bar overflow menu opening a small dialog with the toggle).
- A pure-ish helper `Haptics.pulse(HapticKind)` that: no-ops when `hapticsEnabled` is false; no-ops on platforms without haptics (desktop/web — guard on `defaultTargetPlatform` ∈ {android, iOS}); otherwise calls the matching `HapticFeedback` API (`selectionClick` for toggles, `lightImpact` for pushbutton press). Never throws.
- Wired into the **HMI operator interactions** in `hmi_dashboard_builder_screen.dart` RUN mode ONLY (not config/edit mode): `PushbuttonSwitch` press (and its auto-release), `ToggleSwitch`/`SelectorSwitch` change, and any other momentary/input component that writes a tag on operator tap. The hook sits at the operator-write sites (alongside `_setTagValue`).

### B. Native mobile readiness
- **iOS** (`ios/Runner/Info.plist`): add `NSLocalNetworkUsageDescription` with a clear string (e.g. "Soft PLC Simulator hosts industrial protocol servers (OPC UA, Modbus, MQTT, DNP3) on your local network so SCADA clients can connect, and connects to local MQTT brokers."). This is what makes the in-app servers + the MQTT client work on iOS (the OS prompts the operator on first use). Document that Bonjour service advertisement is out of scope (v1 binds raw TCP listeners; no `NSBonjourServices` needed).
- **Android** (`android/app/src/main/AndroidManifest.xml`): ensure `<uses-permission android:name="android.permission.INTERNET"/>` is declared for the release manifest (binding a `ServerSocket` and outbound sockets require it). `ACCESS_NETWORK_STATE` optional (for surfacing connectivity) — include only if trivially useful.
- **Release build config scaffolding:**
  - Android: a signing config in `android/app/build.gradle.kts` that reads an (untracked, gitignored) `android/key.properties` so `flutter build appbundle --release` works once the user drops in their own keystore; `versionCode`/`versionName` sourced from `pubspec.yaml`. NO keystore or credentials committed (`key.properties`, `*.jks`, `*.keystore` added to `.gitignore`).
  - iOS: signing is Xcode/Apple-account-side — documented, not scripted.
- **Packaging/release doc** (`docs/mobile-packaging.md`): icon/splash regeneration commands (already-configured `flutter_launcher_icons` / `flutter_native_splash`), the permissions rationale (esp. the iOS Local Network prompt being REQUIRED for protocol hosting), the Android keystore + `key.properties` + `flutter build appbundle` flow, the iOS signing + `flutter build ipa` flow, and on-device validation steps (see the SCADA validation guide; confirm the Local Network prompt appears and a SCADA connects).

**Out (v-next):** actual signing / keystore creation / provisioning profiles / store submission (user's accounts); Bonjour/mDNS service advertisement of the protocol ports; push notifications; deep links; per-widget haptic intensity config; iOS/Android widget/complication; background execution / keep-alive while backgrounded (the hosts run while the app is foregrounded — background hosting is a separate concern).

## Architecture

| Unit | File | Responsibility |
|---|---|---|
| App settings store (NEW) | `mobile/lib/services/app_settings.dart` | A minimal `AppSettings` (`hapticsEnabled`, default true) loaded/saved via `SharedPreferences`; a `ChangeNotifier` or a simple load/save + in-memory value the shell holds. Pure-ish (only `SharedPreferences`). |
| Haptics helper (NEW) | `mobile/lib/services/haptics.dart` | `Haptics.pulse(kind)` gated on the enabled flag + platform; wraps `HapticFeedback`. Never throws; no-op off-mobile/off-toggle. |
| Settings UI (MODIFIED) | `mobile/lib/screens/workspace_shell.dart` | An app-bar overflow **Settings** item → a dialog with the haptics toggle (persists via `AppSettings`). |
| HMI operator haptics (MODIFIED) | `mobile/lib/screens/hmi_dashboard_builder_screen.dart` | Call `Haptics.pulse(...)` at the pushbutton/toggle/momentary operator-write sites in RUN mode. |
| iOS permission (MODIFIED) | `mobile/ios/Runner/Info.plist` | `NSLocalNetworkUsageDescription`. |
| Android permission (MODIFIED) | `mobile/android/app/src/main/AndroidManifest.xml` | `INTERNET` uses-permission. |
| Android release config (MODIFIED) | `mobile/android/app/build.gradle.kts`, `mobile/.gitignore` | Signing config via `key.properties`; version from pubspec; gitignore keystore/key.properties. |
| Docs (NEW) | `docs/mobile-packaging.md` | Packaging/release + on-device validation guide. |
| ROADMAP (MODIFIED) | `ROADMAP.md` | Phase 7 haptics + native-readiness marked ✅ (packaging/signing itself remains user-side, noted). |

## Testing

1. **Haptics unit/widget tests** (`haptics_test.dart` + an HMI widget test): `Haptics.pulse` is a no-op when `hapticsEnabled` is false and when the platform isn't mobile (assert no `HapticFeedback` platform message via a mock binary messenger / captured system calls); with haptics enabled and platform forced to `android`/`iOS` (via `debugDefaultTargetPlatformOverride`), a pushbutton press in RUN mode emits exactly one `HapticFeedback` platform call, and a config-mode interaction emits none. `AppSettings` round-trips `hapticsEnabled` through `SharedPreferences` (mock).
2. **Config-content tests** (`native_config_test.dart`): a Dart test reads `ios/Runner/Info.plist` and asserts it contains `NSLocalNetworkUsageDescription` with a non-empty string; reads `android/app/src/main/AndroidManifest.xml` and asserts the `INTERNET` permission is present. This is a regression guard so these functional permissions can't silently disappear.
3. **Build/compile validation:** `flutter analyze` ZERO; full `flutter test` green; `flutter build web --release` compiles; a best-effort `flutter build apk --debug` if the Android toolchain is available in-environment (report honestly if it isn't — iOS build is inherently macOS-only and is validated by the user on-device). The authoritative on-device proof (Local Network prompt appears; a SCADA connects to a phone-hosted server) is a documented user step.
4. **Regression:** WS6 lossless round-trip guard unaffected (no project-schema change — `hapticsEnabled` is app-level, not per-project); no RenderFlex overflow at 320/360/1400 for the new Settings dialog.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix").
- Zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400; dark theme; braces; `const`; `withValues(alpha:)`.
- **Secrets:** never commit keystores, certs, or `key.properties`; add them to `.gitignore`. Signing credentials are the user's and are never handled here.
- Haptics never throw and are a no-op on unsupported platforms and when disabled; wiring is RUN-mode operator interactions only (config-mode edits don't buzz).
- App-level settings are additive and independent of the per-project `ProtocolSettings`; no project-schema change; WS6 round-trip stays green.
- The iOS `NSLocalNetworkUsageDescription` string must accurately describe the protocol-hosting purpose (App Store review reads it).

## Phasing (one spec → plan tasks)

1. **Haptics** — `AppSettings` (SharedPreferences) + `Haptics.pulse` helper + Settings dialog in the shell + wiring into HMI pushbutton/momentary/toggle operator interactions; haptics unit + widget tests.
2. **Native readiness** — iOS `NSLocalNetworkUsageDescription`, Android `INTERNET` permission, Android release signing-config scaffolding via `key.properties` (+ gitignore), version from pubspec; config-content regression tests.
3. **Docs + validation + final review** — `docs/mobile-packaging.md`, ROADMAP Phase 7 update, `flutter analyze`/`test`/`build web`/best-effort `build apk`, whole-branch review, merge.
