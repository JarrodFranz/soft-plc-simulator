# Native-app / store readiness — Design Spec

**Status:** design complete, ready to plan
**Date:** 2026-08-08
**Branch base:** `main` @ `9928474`
**Predecessors:**
`2026-07-06-native-app-readiness-design.md` (WS8 — the *cosmetic* pass:
platform scaffolds, identity, icon/splash, SHIPPING.md. **Shipped.** Its
"Not in scope of this readiness pass" list is now owned by this spec) and
`2026-07-09-mobile-polish-haptics-native-readiness-design.md` (Part A —
haptics — **shipped**; Part B — network permissions, signing scaffold,
`docs/mobile-packaging.md` — **never planned, never executed**. This spec
supersedes Part B). See §9.

## Changelog

- 2026-08-08 — initial design.

---

## Goal

Make the repo **shippable to the Google Play Store and the Apple App Store the
moment the user has developer accounts**, and make the app actually *work* on a
real device once installed.

Today it does not. The audit this spec is built on found that the WS8 pass
delivered every *cosmetic* prerequisite (scaffolds, bundle id
`com.jarrodfranz.softplcsimulator`, display name, icons, splash, a SHIPPING
guide) and **zero** of the *functional* ones. The headline consequence:

> `mobile/android/app/src/main/AndroidManifest.xml` declares **no permissions at
> all**. `INTERNET` is declared *only* in the `debug/` and `profile/` source-set
> manifests that Flutter's template ships — which is precisely why nobody
> noticed: `flutter run` and every local debug build merge it in and work
> perfectly. The **release** merge uses `main/` alone, so a release APK/AAB
> built from this tree cannot open a socket.
> **All nine in-app protocol hosts are dead in a release build**
> — OPC UA, Modbus TCP, MQTT, DNP3, EtherNet/IP, S7, FINS, SLMP, BACnet/IP.
> The single product claim of ADR-010 ("all protocols hosted in-app, pure
> Dart") does not survive `flutter build appbundle --release`.

Alongside that, this spec closes the remaining store-readiness gaps: iOS local
network permission, macOS network entitlements, opt-in release signing, an
app-lifecycle policy (there is none today — `AppLifecycleState` and
`WidgetsBindingObserver` appear **nowhere** in the repo), CI, and the doc/asset
checklists that make the first submission a mechanical exercise.

---

## Scope

**In scope**

1. **Platform network configuration** (§1): Android `INTERNET`; iOS
   `NSLocalNetworkUsageDescription`; macOS `network.server` + `network.client`
   entitlements in both Release and DebugProfile.
2. **Android release signing scaffold** (§1.4): `key.properties`-driven, with a
   graceful fallback to the debug key when absent.
3. **App-lifecycle handling** (§2): a user setting *"Pause automation when app
   is in background"* defaulting to **pause**, with a suspend/resume state
   machine over the scan loop and the nine hosts.
4. **CI** (§3): a GitHub Actions workflow — test+analyze gate, Android AAB
   (signed if secrets exist), iOS no-codesign build, Windows zip.
5. **The four open PR #18 UX-polish DEFERRED rows** (§4).
6. **`generated_plugin_registrant` churn decision** (§5).
7. **Identity**: `pubspec.yaml` `0.1.0+1` → **`0.9.0+2`** (§1.5).
8. **Staleness fixes** (§1.5, §8): `web/manifest.json` + `web/index.html`
   "A new Flutter project."; `PROJECT_BRIEF.md` Risks §3 (Rust FFI).
9. **Docs** (§8): SHIPPING.md overhaul incl. a **store-listing asset checklist**
   (screenshots, feature graphic, privacy policy, content rating) and a
   keystore-generation checklist, both explicitly **user-owned**;
   `docs/mobile-packaging.md`.

**Out of scope** (see §10 for the full deferred registry entries)

- Creating store accounts, generating keystores/certificates, provisioning
  profiles, uploading builds, writing the store listing copy. **User-owned by
  construction** — the repo is made *ready*, never *submitted*.
- True background execution (Android foreground service, iOS `BGTaskScheduler`).
  The setting decides whether to *pause cleanly*, not how to *keep running*.
- macOS App Store / notarised DMG; Linux packaging (Flatpak/Snap/deb); MSIX.
- The iOS multicast entitlement application (§1.6) — needs a paid Apple account.

---

## North-star decisions (binding)

| # | Decision | Rationale |
|---|---|---|
| N1 | **Stay 0.x.** Bump to `0.9.0+2` for the first submission. | Beta signal to reviewers and users. `+2` because `+1` was never published; build numbers must increase monotonically per store, and starting at 2 leaves no ambiguity about which build is the first uploaded one. |
| N2 | **Keep the name and bundle id** (`Soft PLC Simulator`, `com.jarrodfranz.softplcsimulator`). | Bundle ids are effectively immutable after first publish; the current one is already correct and applied everywhere. |
| N3 | **iOS builds via cloud CI**, never locally. | The dev machine is Windows. GitHub Actions `macos-latest` is the only iOS toolchain in reach. |
| N4 | **Every signing-secret-dependent step degrades gracefully.** CI signs when secrets are configured and produces an unsigned artifact when they are not; Gradle signs when `key.properties` exists and falls back to the debug key when it does not. | There are no store accounts yet. A red CI on a fresh clone would be a permanent false alarm; a build that *cannot* run without secrets would block all local release smoke-testing. |
| N5 | **Backgrounding is a user setting, defaulting to PAUSE.** | Cleanly closing sockets on background is the honest behaviour: iOS suspends the process regardless, so leaving hosts "running" just means clients see a half-open TCP connection that never FINs. The OFF position preserves today's behaviour for users who want Android to keep hosting. |
| N6 | **A host the user stopped manually must never restart on foreground.** | The resume set is captured *from live host status at suspend time*, so a manually-stopped host is not in it. See §2.4 for the resume-race handling. |
| N7 | **The permissions can never silently regress.** A guard test greps the built platform config files. | This spec exists because a permission was silently missing for a month across two specs. A test is the only thing that makes that structurally impossible to repeat. |
| N8 | **No new runtime dependency.** | Everything here is platform config, `WidgetsBindingObserver` (framework), `SharedPreferences` (already a dependency), and YAML. |

---

## §1 — Platform configuration changes

Every change below is stated as an exact file path plus the exact text to add.

### §1.1 Android — network permission

**File:** `mobile/android/app/src/main/AndroidManifest.xml`

Insert immediately after the opening `<manifest …>` tag, **before**
`<application>` (the conventional position; the merger accepts either, but
lint prefers permissions first):

```xml
    <!-- Required by every in-app protocol host (ADR-010): binding the OPC UA /
         Modbus TCP / DNP3 / EtherNet/IP / S7 / SLMP listeners, the FINS and
         BACnet/IP UDP sockets, and the outbound MQTT client connection. The
         src/debug/ and src/profile/ manifests already declare this (for the
         Flutter tool's hot-reload channel), which is why `flutter run` works
         without it -- but the RELEASE merge uses src/main/ alone, so without
         this line every host fails to open a socket on a store build.
         Do not remove -- test/platform_config_guard_test.dart enforces it. -->
    <uses-permission android:name="android.permission.INTERNET"/>
```

**Verified:** `mobile/android/app/src/debug/AndroidManifest.xml` and
`mobile/android/app/src/profile/AndroidManifest.xml` each already contain
exactly this `<uses-permission>` line, with Flutter's stock
"required for development" comment. Only `src/main/` — the one the release
variant merges — is missing it. **Do not "fix" this by deleting the debug/profile
declarations**; they are Flutter template files and are correct as they stand.

**`ACCESS_NETWORK_STATE` — verified NOT needed and deliberately NOT added.**
A repo-wide grep for `connectivity`, `NetworkInfo`, and `ACCESS_NETWORK_STATE`
across `mobile/lib` and `mobile/pubspec.yaml` returns **zero hits**. Nothing in
the app inspects connectivity state; the hosts bind and report their own
`status` enum. Declaring an unused permission is a (small) store-review
liability and an unnecessary line in the app's permission list. Adding it later
is a one-line change if a connectivity indicator is ever built.

**`CHANGE_WIFI_MULTICAST_STATE` — not needed.** `bacnet_host.dart:250` sends to
`InternetAddress('255.255.255.255')`, a *directed broadcast*, not a multicast
group; it never calls `joinMulticast`. Android needs no extra permission to send
subnet broadcast, and no `MulticastLock` for it.

### §1.2 iOS — local network usage description

**File:** `mobile/ios/Runner/Info.plist`

Add inside the top-level `<dict>` (alphabetical position: between
`<key>LSRequiresIPhoneOS</key><true/>` and `<key>UIApplicationSceneManifest</key>`):

```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>Soft PLC Simulator hosts industrial protocol servers (OPC UA, Modbus TCP, EtherNet/IP, S7, FINS, SLMP, DNP3, BACnet/IP) on your local network so SCADA and HMI clients can connect, and connects to local MQTT brokers.</string>
```

This is the **exact string** to ship. It names what the app does with the LAN in
operator language; App Review rejects vague purpose strings, and iOS 14+
*silently* fails LAN sockets when the key is missing (no exception, no error —
`ServerSocket.bind` succeeds and no client ever reaches it), which is the worst
possible failure mode to debug on-device.

**`NSBonjourServices` — verified NOT needed.** A repo-wide grep for `Bonjour`,
`mdns`, `multicast_dns`, and `NSNetService` across `mobile/lib` and
`mobile/pubspec.yaml` returns **zero hits**. Every host binds a raw TCP
`ServerSocket` or a raw UDP `RawDatagramSocket` on a fixed, user-configured
port (`opcua_host.dart:438`, `modbus_host.dart:460`, `dnp3_host.dart:409`,
`enip_host.dart:663`, `s7_host.dart:611`, `slmp_host.dart:353`,
`fins_host.dart:186`, `bacnet_host.dart:196`); none advertises a service.
`NSBonjourServices` is required only to *browse or advertise* mDNS services.
This confirms the 2026-07-09 spec's scoping call.

### §1.3 macOS — network entitlements

**File:** `mobile/macos/Runner/Release.entitlements` — replace the whole `<dict>`:

```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
```

**File:** `mobile/macos/Runner/DebugProfile.entitlements` — add the one missing
key (`network.server` is already present; `network.client` is not):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

Both are needed: `network.server` for the eight listening hosts,
`network.client` for the MQTT publisher's outbound broker connection (and for
OPC UA's outbound responses to be unimpeded under the sandbox). Release having
*neither* means a sandboxed release macOS build hosts nothing at all.

### §1.4 Android — opt-in release signing

**File:** `mobile/android/app/build.gradle.kts`

Add at the top of the file, above `plugins { … }`:

```kotlin
import java.io.FileInputStream
import java.util.Properties
```

Add above the `android { … }` block:

```kotlin
// Release signing is OPT-IN and USER-OWNED. `android/key.properties` and the
// keystore it points at are gitignored and absent from a fresh clone (and from
// CI unless the ANDROID_KEYSTORE_* secrets are configured). When present the
// release build is signed with the upload key; when absent it falls back to the
// debug key so `flutter build apk --release` still works for local smoke tests
// and unsigned CI artifacts. See SHIPPING.md for keystore generation.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) FileInputStream(keystorePropertiesFile).use { load(it) }
}
```

Replace the `buildTypes { … }` block and add `signingConfigs`:

```kotlin
    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Unsigned-for-store fallback: debug keys keep
                // `flutter build apk --release` working without secrets.
                signingConfigs.getByName("debug")
            }
        }
    }
```

The existing `// TODO: Add your own signing config for the release build.`
comment is **deleted** (it is now done).

**`rootProject.file("key.properties")`** resolves from `app/build.gradle.kts` to
`mobile/android/key.properties`, which is exactly the path already covered by
`mobile/android/.gitignore`.

**New tracked file:** `mobile/android/key.properties.example` — a committed
template so the shape is discoverable without the real file:

```properties
# Copy to key.properties (gitignored) and fill in from YOUR upload keystore.
# NEVER commit key.properties or the .jks/.keystore file it points at.
storePassword=CHANGE_ME
keyPassword=CHANGE_ME
keyAlias=upload
storeFile=C:/path/to/upload-keystore.jks
```

**Gitignore audit (verified).** `mobile/android/.gitignore` already contains
`key.properties`, `**/*.keystore`, and `**/*.jks`. The **root** `.gitignore`
contains `*.jks` but **not** `key.properties` or `*.keystore`. Add both to the
root "Secrets - NEVER commit these" block as defence-in-depth (a keystore
dropped anywhere in the tree, not just under `mobile/android/`, must be
ignored), plus an explicit negation so the example template stays tracked:

```gitignore
*.keystore
key.properties
!**/key.properties.example
```

### §1.5 Version bump and staleness fixes

| File | Change |
|---|---|
| `mobile/pubspec.yaml` | `version: 0.1.0+1` → `version: 0.9.0+2` |
| `mobile/web/manifest.json` | `"description": "A new Flutter project."` → `"description": "A soft PLC simulator: IEC 61131-3 programs, HMI dashboards, and nine in-app industrial protocol servers."` |
| `mobile/web/index.html` | `<meta name="description" content="A new Flutter project.">` → the same string as above |
| `PROJECT_BRIEF.md` Risks §3 | Replace the retired Rust-FFI risk (see below) |

`PROJECT_BRIEF.md` Risks item 3 currently reads *"Cross-Platform FFI Overhead:
Passing tag updates between Rust core and Flutter UI across native boundary"*
with a `flutter_rust_bridge` mitigation. That architecture was retired by
ADR-010 (all protocols pure Dart, in-app, no companion service) and the
`runtime/`/`gateway/` Rust crates no longer exist in the build. Replace with the
risk that actually applies now:

> 3. **Single-isolate scan + protocol load**: the scan loop, the nine protocol
>    hosts, and the UI all share one Dart isolate; a heavy scan or a chatty
>    client can starve the frame budget.
>    - *Mitigation*: the throttled `LiveTick` repaint decoupling
>      (`widgets/live_tick.dart`) keeps UI repaint off the scan tick, the
>      free-run loop yields to the event loop between scans
>      (`workspace_shell.dart:434-455`), and per-task watchdogs surface
>      overruns instead of hiding them.

Note `SHIPPING.md`'s "Version: `0.1.0+1`" line and its "1550 tests pass" claim
must be re-derived, not copied, during the docs task (§8).

### §1.6 The BACnet broadcast caveat (new finding — not in the audit)

`bacnet_host.dart:245-255` sends a startup I-Am to `255.255.255.255`. On
**iOS 14+**, sending to a broadcast or multicast address requires the
**`com.apple.developer.networking.multicast`** entitlement, which Apple grants
only by application against a *paid* developer account and which cannot be
self-issued. `NSLocalNetworkUsageDescription` does **not** cover it.

**Decision: accept the degradation, do not block on it.** The code already
wraps the broadcast in a try/catch whose comment states that a broadcast
failure "must never prevent the host from starting" — so on iOS the BACnet host
still binds 47808, still answers directed `Who-Is` from a client that knows its
address, and only loses the unsolicited startup announcement, with the existing
log line explaining why. This is documented in `docs/protocols/bacnet.md` and
in the SHIPPING.md iOS checklist as a *known iOS-only limitation with a stated
remedy* (apply for the entitlement once an Apple account exists). It is
recorded in `docs/DEFERRED.md`.

---

## §2 — App-lifecycle design (the risky one)

### §2.0 What exists today

Verified against `mobile/lib/screens/workspace_shell.dart`:

| Thing | Location | Note |
|---|---|---|
| `WorkspaceShellState` | `:102` | `State<WorkspaceShell>`, **no mixin** |
| `isRunning` | `:116` | user-facing Run/Pause intent, toggled at `:2209` |
| `_scanTimer`, `_supervisorTimer` | `:119-120` | armed by `_startScanLoop()` `:434` |
| `_startScanLoop()` | `:434-462` | mode-aware: `Timer.periodic` (fixed) or a self-re-arming zero-delay `Timer` (free-run); also arms the 200 ms supervisor |
| `_executeScan()` | `:833` | `dtMs` derived from `_sinceLast`, **clamped to 1000 ms** at `:838` |
| `_startRunSession()` | `:822` | resets `_scan` runtime + the `_uptime`/`_sinceLast` stopwatches |
| `_uptime`, `_sinceLast` | `:189-190` | `Stopwatch`es; `_uptime` feeds `System.Uptime` at `:902` |
| The nine hosts | `:135-143` | `late final`, owned by the shell, passed into `GatewayScreen` |
| `dispose()` | `:279-294` | cancels all timers, disposes all nine hosts |
| Settings keys | `:63,:72` | `ui_refresh_hz`, `haptics_enabled` |
| `applyRefreshHz` / `applyHapticsEnabled` | `:561`, `:537` | `@visibleForTesting`, best-effort persist |
| `_flushPendingAutosave()` | `:1103-1108` | cancels the debounce and runs the write now; **already** calls `_flushActiveEditor()` (`:1096`) first |
| Settings load | `:328-338` | inside `_boot()`, reusing the `prefs` handle |

Host API (uniform across all nine, verified): `ChangeNotifier`, a
`<Name>HostStatus get status` getter over an enum containing `running`,
`Future<void> start(PlcProject Function() projectProvider)`, `Future<void> stop()`.
`GatewayScreen` drives them through eighteen one-line private helpers
(`gateway_screen.dart:573-644`), e.g. `_startHosting` → `widget.host.start(() => widget.currentProject)`.

### §2.1 The state machine

`WorkspaceShellState` gains `with WidgetsBindingObserver`;
`WidgetsBinding.instance.addObserver(this)` in `initState()` (after
`_repaintThrottle` construction, before `_boot()`), and
`removeObserver(this)` as the **first** line of `dispose()`.

| `AppLifecycleState` | Platform reality | Action |
|---|---|---|
| `resumed` | app is foreground and interactive | **Resume** (§2.3), if currently lifecycle-suspended |
| `inactive` | transient: iOS Control Centre / notification shade / incoming-call banner / app-switcher preview; desktop window focus loss | **No-op.** Suspending here would close every socket because the user swiped down a notification. This is the single most common lifecycle bug and is called out explicitly so nobody "helpfully" adds it. |
| `hidden` | transitional, immediately precedes `paused` on mobile; the *deepest* state a desktop window reaches | **Flush only** (§2.2 step 1). Never suspends. |
| `paused` | mobile only — the OS has backgrounded the app | **Suspend** (§2.2), if the setting is on and the platform is mobile |
| `detached` | engine teardown, no view attached | **Unconditional clean stop** of all nine hosts, regardless of the setting. No resume state is recorded — there is nothing to resume into. Best-effort and bounded; `dispose()` remains the real teardown. |

**Platform gate (binding).** Suspend/resume applies only when
`defaultTargetPlatform` is `TargetPlatform.android` or `TargetPlatform.iOS`
**and** `!kIsWeb`. On Windows/macOS/Linux a minimised or unfocused window
*should* keep hosting — that is the whole point of the desktop build — and
`hidden` there is a normal minimise, not a background. The setting's UI is
disabled with an explanatory subtitle on those platforms (§2.5).

**New state fields** on `WorkspaceShellState`:

```dart
/// True between a lifecycle suspend and its matching resume. Consulted by
/// [_startScanLoop]'s free-run re-arm guard so a suspend genuinely stops the
/// chain rather than letting it re-arm itself.
bool _lifecycleSuspended = false;

/// Hosts that were `running` at suspend time and are therefore eligible to be
/// restarted on resume. A host the user stopped manually beforehand is not in
/// this set, so it stays stopped (N6).
final Set<String> _resumeHostIds = <String>{};

/// Bumped by every suspend, every `detached`, and every MANUAL host toggle on
/// the Gateway screen. The resume loop captures it and aborts the remainder of
/// its restarts if it changes mid-flight (§2.4).
int _resumeGeneration = 0;
```

Hosts are addressed by a stable string id (`'opcua'`, `'modbus'`, `'mqtt'`,
`'dnp3'`, `'enip'`, `'s7'`, `'fins'`, `'slmp'`, `'bacnet'`) through one private
table so the nine-way fan-out is written once:

```dart
/// (id, displayName, isRunning, start, stop) for each host — the single place
/// the nine hosts are enumerated for lifecycle purposes.
List<_LifecycleHost> get _lifecycleHosts => [ … ];
```

### §2.2 Suspend sequence

Triggered on `hidden` (flush only) and `paused` (full suspend). Ordered,
idempotent, and individually failure-tolerant — the OS gives a backgrounding app
a short, unspecified budget and may kill it mid-sequence.

1. **Flush pending writes — ALWAYS, regardless of the setting.** Call the
   existing `_flushPendingAutosave()` (`workspace_shell.dart:1103-1108`) —
   which already drains the ST editor's 350 ms debounce buffer via
   `_flushActiveEditor()` and then cancels the 800 ms `_autosaveTimer` and runs
   the write immediately. **Reuse it; do not open-code the sequence.** Without
   this, an edit made in the last 800 ms before backgrounding is lost whenever
   iOS reclaims the process — a **data-loss bug that exists today** and that
   this step fixes independently of the pause feature. It is not gated on the
   setting because it is a durability measure, not automation control.
2. Return here if the setting is off, the platform is not mobile, or
   `_lifecycleSuspended` is already true.
3. `_lifecycleSuspended = true;` and `_resumeGeneration++`.
4. Capture `_resumeHostIds` from **live status**: every host whose
   `status` is its enum's `running`.
5. Cancel `_scanTimer` and `_supervisorTimer`. **`isRunning` is deliberately
   left untouched** — it is the user's Run/Pause *intent* and must be exactly
   what it was when they return. `_startScanLoop()`'s free-run `arm()` guard and
   its fixed-mode `Timer.periodic` body each gain `&& !_lifecycleSuspended`.
6. `_uptime.stop();` — `System.Uptime` should mean "time the PLC was actually
   scanning", not wall-clock including a suspended night. `Stopwatch` preserves
   elapsed across stop/start, so nothing is lost.
7. Stop the hosts in `_resumeHostIds`, each in its own `try`/`catch`, awaited
   together under a bounded overall timeout (**2 s**) so a wedged socket cannot
   consume the whole background budget. Timeout is logged, not thrown.
8. Log one `INFO` line under `kLogSourceLifecycle` naming the count and the
   ids, e.g. `Backgrounded: scan paused, 3 host(s) stopped (opcua, modbus, mqtt).`

**The historian is deliberately untouched.** `TagHistorian` is a memory-only,
tick-driven ring buffer; with no ticks arriving it simply records no samples, so
a background period shows as a gap in the trend. That is the honest rendering
and needs no special handling — documented in `docs/trends.md`.

### §2.3 Resume sequence

Triggered on `resumed`.

1. Return if `!_lifecycleSuspended`.
2. `_lifecycleSuspended = false;`
3. `_sinceLast..reset()..start();` so the first post-resume `dtMs` is a real
   tick interval rather than the background duration. (`_executeScan` already
   clamps `dtMs` to 1000 ms at `:838`, so this is belt-and-braces — but a 1000 ms
   step into a PID loop tuned for 500 ms is still a visible bump.)
4. `_uptime.start();`
5. `_startScanLoop();` — re-arms per the *current* `isRunning`/`_freeRun`, which
   were never mutated, so the user's Run/Pause state is exactly preserved.
6. Restart hosts (§2.4).
7. Clear `_resumeHostIds`.
8. Surface the outcome (§2.6) via a post-frame callback —
   `WidgetsBinding.instance.addPostFrameCallback` — because `resumed` can be
   delivered before the first frame of the restored view, and
   `ScaffoldMessenger.of(context)` needs a laid-out scaffold.

### §2.4 Restart, and the interaction with the Gateway's manual toggles (N6)

The restart loop is **sequential, not parallel**: nine simultaneous binds
(one of which loads and parses an RSA-2048 certificate in `OpcUaHost.start()`)
on a phone that just woke up is a needless thundering herd, and sequential
execution gives a deterministic log order for support.

Before starting each host `H`:

- **Abort the whole remainder** if `_resumeGeneration != generationCapturedAtResumeStart`.
- **Skip `H`** if `H.status != stopped` (someone already started it, or it never
  stopped).
- Otherwise `await H.start(() => _activeProject)` in a `try`/`catch`; a failure
  (port taken by another app, permission denied) leaves `H` stopped, is logged,
  and is named in the resume banner. It does **not** abort the remaining hosts.

**Bumping the generation on a manual toggle.** `GatewayScreen` gains one
optional callback parameter:

```dart
/// Invoked whenever the USER starts or stops a host from this screen. The
/// shell uses it to abandon an in-flight lifecycle resume (§2.4 of the
/// store-readiness spec): a host the user is touching right now must win over
/// a restart decision made before the app was backgrounded.
final VoidCallback? onManualHostToggle;
```

called as the first statement of each of the eighteen
`_start*Hosting`/`_stop*Hosting` helpers at `gateway_screen.dart:573-644`. The
shell passes `onManualHostToggle: () => _resumeGeneration++`.

Eighteen hand-edited call sites is exactly the kind of change where one gets
missed, so §6 specifies a **source-grep guard test** that reads
`gateway_screen.dart` and asserts every method matching
`_(start|stop)\w*Hosting\(` contains `widget.onManualHostToggle?.call()`.

### §2.5 The setting: persistence, dialog, and copy

**Key & default** — alongside the two existing global keys in
`workspace_shell.dart`:

```dart
/// Global (not per-project) SharedPreferences key for whether the scan loop and
/// the protocol hosts are paused while the app is backgrounded.
const String _kPauseInBackgroundKey = 'pause_in_background';

/// Default for background pausing: ON. Cleanly closing sockets is the honest
/// behaviour -- iOS suspends the process regardless, so "keep running" there
/// only means clients hold a half-open TCP connection that never FINs.
const bool kDefaultPauseInBackground = true;
```

Loaded in `_boot()` beside the other two (`:328-338`, same best-effort
`try`/`catch`), applied through a new
`@visibleForTesting Future<void> applyPauseInBackground(bool)` written in the
exact shape of the existing `applyHapticsEnabled` (`:537-551`): mounted-guarded
`setState`, then a best-effort `prefs.setBool`.

**Dialog** — `softplc_settings_dialog.dart`:
`SoftPlcSettingsResult` gains `final bool pauseInBackground;`;
`SoftPlcSettingsDialog` gains `initialPauseInBackground`; a third
`SwitchListTile` is appended below the haptics one. Copy (exact):

```
title:    Pause automation when app is in background
subtitle (mobile, enabled):
          On: the scan loop pauses and all protocol hosts close their sockets
          cleanly when you leave the app, then resume when you come back.
          Off: the OS decides — iOS suspends the app anyway; Android keeps
          hosting while the app is alive.
subtitle (desktop/web, switch disabled):
          Mobile only. A minimised or unfocused desktop window keeps scanning
          and hosting.
```

The per-platform reality is stated *in the dialog*, not only in the docs —
this is the one place a user will look when a client drops on lock-screen.

`_openSoftPlcSettings` (`:588-601`) awaits `applyPauseInBackground(result.pauseInBackground)`
alongside the two existing applies.

### §2.6 The resume banner

A `SnackBar` (not a persistent banner — it is informational, not actionable),
posted from the post-frame callback, with content derived from the restart
outcome:

- All restarted, nothing failed:
  `Resumed. Scan running; 3 protocol host(s) restarted.`
- Scan was paused by the user before backgrounding:
  `Resumed. Scan is paused; 3 protocol host(s) restarted.`
- Partial failure (`duration: 6s`, action `View logs` opening the Logs screen
  filtered to `Lifecycle`):
  `Resumed. 2 of 3 protocol host(s) restarted — Modbus TCP failed (port 502 in use). See Logs.`
- Nothing was running at suspend time: **no snackbar at all** (there is nothing
  to report and an unconditional toast on every app-switch would be noise).

### §2.7 Logging

Per the repo's protocol-logging rule, a new source constant is added to
`mobile/lib/models/app_log.dart` **and** to `kAllLogSources` (the existing guard
test in `app_log_test.dart` enforces the pair):

```dart
const String kLogSourceLifecycle = 'Lifecycle';
```

Levels: `INFO` for each suspend and resume summary; `WARN` for a host that
failed to stop within the timeout or failed to rebind on resume; `DEBUG` for
the per-host stop/start transitions and the aborted-generation case.

---

## §3 — CI workflow design

**New file:** `.github/workflows/ci.yml`. No CI exists today (no `.github/`, no
`codemagic.yaml`).

**Repo visibility — verified `public`** (`GET /repos/JarrodFranz/soft-plc-simulator`
→ `private=false, visibility=public`). Consequence: **GitHub-hosted runners,
including `macos-latest`, are free with no minute charges on public
repositories**, so the iOS job costs nothing today. If the repo is ever flipped
to private, macOS minutes bill at **10× the Linux multiplier** against the free
allowance and the iOS job becomes the dominant cost. The workflow therefore
gates the two expensive jobs (`ios`, `windows`) so a private-repo future can
throttle them by editing one `if:` rather than restructuring:

```yaml
env:
  # Set to 'false' to skip the expensive macOS/Windows runners (e.g. if this
  # repo ever becomes private, where macOS bills at a 10x minute multiplier).
  BUILD_PLATFORM_ARTIFACTS: 'true'
```

**Triggers**

```yaml
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**Pinning.** `subosito/flutter-action@v2` with `flutter-version: 3.44.4` and
`channel: stable` — the exact version the dev machine runs
(`Flutter 3.44.4 • stable`), pinned so CI never diverges from local. Java 17
(`actions/setup-java@v4`, `temurin`) for the Android job, matching the
`sourceCompatibility`/`jvmTarget` already set in `build.gradle.kts`.

**Jobs**

| Job | Runner | Needs | Steps | Artifact |
|---|---|---|---|---|
| `gate` | `ubuntu-latest` | — | `flutter pub get`; `flutter analyze` (fails on any issue — the repo's standing "no analyze warnings" rule); `flutter test` | — |
| `android` | `ubuntu-latest` | `gate` | Java 17; decode keystore **if secrets present**; write `key.properties` **if present**; `flutter build appbundle --release`; `flutter build apk --release` | `android-release` (`.aab` + `.apk`) |
| `ios` | `macos-latest` | `gate` | `flutter build ios --release --no-codesign`; zip `build/ios/iphoneos/Runner.app` | `ios-release-unsigned` |
| `windows` | `windows-latest` | `gate` | `flutter build windows --release`; zip `build/windows/x64/runner/Release` | `windows-release` |

All jobs `defaults: run: working-directory: mobile` (every `flutter` command in
this repo runs from `mobile/`).

**The signed-if-secrets pattern (the footgun).** `secrets` is **not** available
in a job-level `if:`, so the gate must be a step-level output. Exact shape:

```yaml
      - name: Detect release keystore
        id: keystore
        env:
          KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
        run: |
          if [ -n "$KEYSTORE_B64" ]; then
            echo "present=true" >> "$GITHUB_OUTPUT"
          else
            echo "present=false" >> "$GITHUB_OUTPUT"
            echo "::notice::No ANDROID_KEYSTORE_BASE64 secret — building with the debug key (unsigned for store upload)."
          fi

      - name: Write keystore and key.properties
        if: steps.keystore.outputs.present == 'true'
        env:
          KEYSTORE_B64:   ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          STORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS:      ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASSWORD:   ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          echo "$KEYSTORE_B64" | base64 -d > "$RUNNER_TEMP/upload.jks"
          {
            echo "storeFile=$RUNNER_TEMP/upload.jks"
            echo "storePassword=$STORE_PASSWORD"
            echo "keyAlias=$KEY_ALIAS"
            echo "keyPassword=$KEY_PASSWORD"
          } > android/key.properties
```

The keystore is written to `$RUNNER_TEMP` (outside the workspace, never
archivable into an artifact) and the four secret names are documented in
SHIPPING.md as **user-owned**: `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
`permissions: contents: read` at workflow level.

**iOS is intentionally unsigned.** `--no-codesign` needs no Apple account, no
certificate, and no provisioning profile; the artifact is a simulator/ad-hoc-shaped
`Runner.app` that proves the iOS toolchain compiles this source tree. Adding
codesigning is a later, secret-gated step exactly like Android's.

**Retention.** `retention-days: 14` on `pull_request` and branch pushes;
`retention-days: 90` when `startsWith(github.ref, 'refs/tags/v')` — the tag
builds are the candidate submission artifacts and should outlive a sprint.

---

## §4 — Absorbed UX-polish (the four open PR #18 DEFERRED rows)

All four live in `docs/DEFERRED.md` under **"QA whole-branch review follow-ups
(feat/qa-improvements)"** (lines 150-153).

### §4.1 Project-dropdown scrim

**Site:** `workspace_shell.dart:2469`, the `DropdownButton<String>` in the
SELECT PROJECT header.

The deferral is correct as stated: `DropdownButton`'s modal barrier colour is
not reachable through its API. **Do not try to recolour it — remove it.**
Replace the `DropdownButton` with a `MenuAnchor` (Material 3) whose anchor is a
`Row(children: [Expanded(Text(activeName, overflow: ellipsis)), Icon(arrow_drop_down)])`
styled to match the current appearance exactly, and whose `menuChildren` are the
same items (`MenuItemButton` with the check-circle/folder leading icon and the
`Tooltip`-wrapped name). A `MenuAnchor` overlay has **no full-screen scrim at
all**, so the mismatched-scrim problem ceases to exist rather than being
papered over. Same `onChanged` → `_switchActiveProject(selected)` behaviour.

Existing widget tests that tap the dropdown by type must be updated to tap the
anchor; the *behaviour* under test (switching projects) is unchanged.

### §4.2 Tags & Structs FAB pinned bottom bar

**Site:** `memory_manager_screen.dart:1500-1513`, `_buildStructDefsTab()`.

Verified: this tab has its **own nested `Scaffold`** with its own
`floatingActionButton`, separate from the outer screen's FAB column at `:721`.
The change is therefore contained to this tab.

Replace the nested `Scaffold` + `FloatingActionButton.extended` with a `Column`:
the `ListView` in an `Expanded`, and below it a pinned action surface —
`SafeArea(top: false, child: Container(padding: EdgeInsets.all(12), color: 0xFF1E293B, child: SizedBox(width: double.infinity, child: FilledButton.icon(icon: add, label: 'Add DUT'))))`.
Drop the ListView's 96 px trailing padding back to a plain
`EdgeInsets.all(16)` — nothing floats over the list any more, so the last card is
clear at **any** scroll position, which is exactly what the deferral asked for.
The empty-state `Center(Text(...))` case keeps the same bottom bar (an empty
list is precisely when the user needs the Add button most).

### §4.3 `PannableCanvas` pointer-signal gap

**Site:** `pannable_canvas.dart:140-153` (`_onPointerSignal`, the
`if (pre == null) return;` early-out) and `:306-323` (the outer `Listener` →
`InteractiveViewer` → inner capture `Listener` → `widget.child` sandwich).

**Root cause:** the inner capture `Listener` is `HitTestBehavior.opaque` but
covers only the *child's laid-out rect*. With `constrained: false` the child is
its intrinsic size, so a viewport larger than the content has dead zones where
the capture never fires, `pre` stays null, and the wheel falls through to
`InteractiveViewer`'s own zoom.

**Fix:** make the capture region cover the viewport. Wrap the inner `Listener`'s
subtree in a `LayoutBuilder` + `ConstrainedBox(minWidth: viewport.maxWidth,
minHeight: viewport.maxHeight)` (the `PannableCanvas`'s own outer constraints,
read once at the top of `build`). When the content is larger than the viewport
nothing changes; when it is smaller, the capture layer now spans the whole
visible area and the `pre == null` branch becomes unreachable in practice. Keep
the branch (and its comment) as a defensive no-op.

**Known side effect to verify, not hide:** enlarging the child changes
`InteractiveViewer`'s pan extent when content < viewport (the child now
*is* viewport-sized). `editor_canvas_pan_test.dart` must stay green, and the
task adds one case asserting a wheel notch over empty canvas space **pans**
rather than zooming.

### §4.4 FBD lane wheel vs. tall networks

**Site:** `fbd_editor_screen.dart:673-681` (`_laneCanvasHeight`, the
`(maxY + 220).clamp(260.0, 1200.0)` ceiling) with `wheelPansVertically: false`
at `:907`.

With vertical wheel deliberately handed to the outer lane `ListView`, any
network content past the 1200 px lane height is wheel-unreachable. The clean fix
is to stop truncating the lane: **let the lane be as tall as its content**, so
the outer `ListView` — which the plain wheel already drives — reaches every
block by definition.

```dart
// No 1200px ceiling: with wheelPansVertically:false the plain wheel drives the
// outer lane ListView, so any content taller than the lane is wheel-
// unreachable. Sizing the lane to its content makes the outer list the single,
// always-sufficient vertical scroller. The 20000px ceiling is a pathological-
// import guard only (drag-pan and Shift+wheel still reach past it).
return (maxY + 220).clamp(260.0, 20000.0);
```

Drag-to-pan and Shift+wheel are unaffected. Existing
`fbd_editor_networks_test.dart` / `editor_canvas_pan_test.dart` must stay green;
one new case asserts a network with a block at `y = 2000` produces a lane taller
than 2000 px.

---

## §5 — The `generated_plugin_registrant` decision

**Facts (verified).** Seven generated files are tracked:
`mobile/linux/flutter/generated_plugin_registrant.{cc,h}` +
`generated_plugins.cmake`, `mobile/windows/flutter/` the same three, and
`mobile/macos/Flutter/GeneratedPluginRegistrant.swift`. The iOS and Android
equivalents are **already ignored** by Flutter's own per-platform templates
(`mobile/ios/.gitignore`: `Runner/GeneratedPluginRegistrant.*`;
`mobile/android/.gitignore`: `GeneratedPluginRegistrant.java`). Across the
entire repo history **exactly one commit** has touched any of them: `c8cc4db`,
the original scaffold.

**Decision: ACCEPT — keep them tracked. Do not gitignore.**

Rationale:

1. **The churn is hypothetical.** One commit in the repo's whole history. The
   dependency set (`shared_preferences`, `file_picker`, `share_plus`,
   `path_provider`) has been stable for months; these files change only when a
   *platform plugin* is added or removed, which is a deliberate, reviewable
   event — and seeing the registrant diff in that PR is a *feature*, not noise.
2. **Flutter's own templates track them for exactly these three platforms** and
   ignore them for the other two. Deviating from that split means every
   `flutter create --platforms` refresh fights the repo.
3. **CMake/Xcode reference them at configure time.** `flutter build` regenerates
   them first, so a clone would recover — but a developer opening
   `windows/runner` in Visual Studio, or anything that configures CMake without
   a prior `flutter pub get`, breaks. Cheap file, real cost to remove.
4. If churn ever *does* appear, gitignoring is a one-line change made with
   evidence; un-ignoring after a broken build is a debugging session.

This decision is recorded in `docs/mobile-packaging.md` so the next person who
notices the files does not re-litigate it.

---

## §6 — Testing

New file **`mobile/test/platform_config_guard_test.dart`** — the N7 regression
wall. `flutter test` runs with CWD = the package root (`mobile/`), so paths are
relative to it (the same assumption `opcua_cert_store_test.dart` already makes).
Each assertion carries a `reason:` naming *what breaks* if it fails, so a future
failure explains itself.

| # | Assertion | File read |
|---|---|---|
| G1 | Contains `android.permission.INTERNET` in a `<uses-permission …/>` element | `android/app/src/main/AndroidManifest.xml` |
| G2 | Contains `<key>NSLocalNetworkUsageDescription</key>` and the `<string>` that follows it is ≥ 40 chars and mentions `local network` | `ios/Runner/Info.plist` |
| G3 | Contains both `com.apple.security.network.server` and `com.apple.security.network.client`, each followed by `<true/>` | `macos/Runner/Release.entitlements` **and** `DebugProfile.entitlements` (parameterised over both) |
| G4 | Contains `rootProject.file("key.properties")` and `signingConfigs.getByName("release")`; does **not** contain the literal `// TODO: Add your own signing config` | `android/app/build.gradle.kts` |
| G5 | `key.properties`, `*.jks`/`**/*.jks`, `*.keystore`/`**/*.keystore` are each covered by at least one of the two gitignores | root `.gitignore`, `android/.gitignore` |
| G6 | Neither contains the string `A new Flutter project.` | `web/manifest.json`, `web/index.html` |
| G7 | `version:` parses as `0.9.0+2` or higher (semver + build both monotonic) | `pubspec.yaml` |
| G8 | Every method matching `_(start\|stop)\w*Hosting\(` contains `onManualHostToggle` (§2.4's eighteen call sites) | `lib/screens/gateway_screen.dart` |

New file **`mobile/test/lifecycle_pause_test.dart`** — lifecycle behaviour, driven
by `tester.binding.handleAppLifecycleStateChanged(...)` against a pumped
`WorkspaceShell` with an injected in-memory `ProjectRepository` (the existing
`widget.repository` seam) and `TestWidgetsFlutterBinding.ensureInitialized()` +
`SharedPreferences.setMockInitialValues`. `debugDefaultTargetPlatformOverride`
is set to `TargetPlatform.android` for the mobile cases and restored in
`tearDown`.

| # | Case |
|---|---|
| L1 | `paused` with the setting ON → scan timer is not firing (`debugBuildCount`/`scanCount` frozen across a pumped 2 s) and the started host reports `stopped` |
| L2 | `resumed` after L1 → scan ticks again and the host is `running` |
| L3 | `inactive` → **nothing** changes (the "notification shade" case) |
| L4 | `hidden` → the pending autosave is flushed, but scan and hosts are untouched |
| L5 | Setting OFF → `paused` changes nothing except the autosave flush |
| L6 | A host stopped **manually** before `paused` is **not** restarted on `resumed` (N6) |
| L7 | User has the scan **paused** (`isRunning == false`) before `paused`; on `resumed` it is still paused — the lifecycle never overrides Run/Pause intent |
| L8 | A restart that throws leaves the other hosts started and produces a `WARN` under `kLogSourceLifecycle` |
| L9 | `_resumeGeneration` bumped mid-restart aborts the remainder (drive by invoking the callback the shell passes to `GatewayScreen`) |
| L10 | `detached` stops every running host even with the setting OFF |
| L11 | `defaultTargetPlatform == windows` → `paused` is a full no-op beyond the flush |

New cases in **`mobile/test/widgets/refresh_rate_pref_test.dart`** — the
existing home of the global-settings apply/persist tests (it already covers
`applyRefreshHz` and `applyHapticsEnabled`); S4/S5's dialog-level cases sit
beside the haptics dialog coverage in `mobile/test/hmi_haptics_test.dart` if
that proves the better fit:

| # | Case |
|---|---|
| S1 | Default is ON when `pause_in_background` was never persisted |
| S2 | `applyPauseInBackground(false)` updates state and writes the key |
| S3 | A failing `SharedPreferences` still applies for the session (the existing best-effort contract) |
| S4 | The dialog round-trips the toggle into `SoftPlcSettingsResult` |
| S5 | On a desktop `defaultTargetPlatform` the switch renders disabled with the mobile-only subtitle |

Plus: `app_log_test.dart`'s existing `kAllLogSources` guard covers
`kLogSourceLifecycle` for free once it is added to both places (it will fail
loudly if only one is done — which is the point).

**Gate:** the full suite green and `flutter analyze` clean, both locally and in
the CI `gate` job. No test may be skipped or marked flaky to land this.

---

## §7 — Verification strategy (Windows dev machine)

| Target | How it is verified | Owner |
|---|---|---|
| **Unit/widget** | `cd mobile && flutter test` — full suite green | local + CI |
| **Static** | `flutter analyze` clean | local + CI |
| **Android release** | `flutter build apk --release` **twice**: once with no `key.properties` (must succeed, debug-signed) and once with a throwaway local keystore (must succeed, release-signed — verify with `keytool -printcert -jarfile`). Then `flutter build appbundle --release`. Install the APK on a device/emulator and confirm a Modbus client on the LAN connects — **this is the proof the whole spec exists for** | local (Windows) |
| **Windows desktop** | `flutter build windows --release` + launch; confirm a host still runs while the window is minimised (§2.1's desktop gate) | local |
| **Web** | The repo's headless-Playwright loop (`scripts/serve-web.sh --build` + screenshots at 1440×900 / 768×1024 / 390×844) for the §4 UX changes — the dropdown, the DUT bottom bar, the FBD lane, and the canvas wheel are all visual/interaction changes and must pass browser verification per CLAUDE.md | local |
| **iOS** | **CI build success is the gate.** `flutter build ios --release --no-codesign` compiling on `macos-latest` is the only iOS signal obtainable without a Mac or an Apple account. It proves the plist and the source tree are valid; it does **not** prove the Local Network prompt appears | CI |
| **On-device iOS / macOS** | A written checklist in SHIPPING.md: install via Xcode → confirm the Local Network prompt text → connect a SCADA client → background the app and confirm the hosts stop → foreground and confirm the resume banner | **user-owned** |
| **Store submission** | Entirely user-owned (§10) | user |

**The honest gap, stated up front:** nothing in this plan can prove the iOS
`NSLocalNetworkUsageDescription` actually works, because that requires a
physical iOS device. The guard test proves the key is *present and well-formed*;
the CI build proves the plist *parses*; the on-device checklist is where it is
finally confirmed. Do not let a green CI be reported as "iOS verified".

---

## §8 — Docs

| Doc | Change |
|---|---|
| `SHIPPING.md` | **Overhaul.** Delete the "Not in scope of this readiness pass" network-permissions bullet (now done). Add: (a) **Keystore generation** — the exact `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload` invocation, where to store it, and the `key.properties` shape, flagged **user-owned, never committed**; (b) **CI secrets** — the four `ANDROID_*` names and where to set them; (c) the **store-listing asset checklist** below; (d) the **on-device validation checklist** from §7; (e) refreshed version (`0.9.0+2`) and a re-derived test count |
| `docs/mobile-packaging.md` | **New.** The per-platform config reference: what each permission/entitlement is for and what breaks without it; the signing fallback semantics; the lifecycle setting's per-platform behaviour; the iOS multicast/BACnet caveat (§1.6); the §5 registrant decision |
| `PROJECT_BRIEF.md` | Risks §3 replaced (§1.5) |
| `docs/DEFERRED.md` | Strike through the four §4 rows with the closing PR; add the new rows from §10 |
| `docs/protocols/bacnet.md` | Add the iOS broadcast caveat (§1.6) |
| `docs/trends.md` | One line: a background pause shows as a gap in the trend (§2.2) |
| `knowledge/practices/development-process.md` | One durable lesson (§8.1) |

### §8.1 The knowledge-base entry

One pattern here is durable and generalises well beyond this workstream:

> **A "config-only" deliverable needs a test or it will silently regress.**
> The `INTERNET` permission was specified in two separate approved specs
> (2026-07-09 Part B) and shipped in neither; nothing failed, because nothing
> *could* fail — no test, no build error, and the debug manifest merge masked
> it in every local run. Config that only matters in a *release* build is
> invisible to a debug workflow by construction. The fix is a cheap
> source-reading guard test (`platform_config_guard_test.dart`) asserting the
> literal key is present, with a `reason:` naming what breaks without it.

Add as a new `CL-` entry under `knowledge/practices/development-process.md`
(the existing `verification.md` "guard test" family is the right neighbour) and
update `knowledge/canonical-manifest.json`.

### §8.2 Store-listing asset checklist (SHIPPING.md content, user-owned)

Every item below is the **user's** to produce and upload; the repo can supply
the screenshots and the disclaimer text.

**Google Play**
- App icon 512×512 PNG (32-bit, alpha) — derivable from `assets/icon/Icon_1024.png`
- **Feature graphic 1024×500** (required; no transparency) — must be authored
- Phone screenshots: 2–8, 16:9 or 9:16, min 320 px shortest side
- 7-inch and 10-inch **tablet** screenshots (required to be listed as
  tablet-supported; the app's responsive layout genuinely earns this)
- Short description ≤ 80 chars; full description ≤ 4000 chars
- **Privacy policy URL — required even though the app collects nothing.** State
  plainly: *the app collects no personal data, has no analytics, no crash
  reporting, no ads, and no network transmission except the protocol servers
  the user explicitly starts on their own LAN.* Projects are stored locally
  (`SharedPreferences`/local files) and leave the device only when the user
  exports a `.splc.json` themselves.
- **Data safety form:** declare *no data collected, no data shared*
- **Content rating** questionnaire (IARC): a developer/engineering utility with
  no user-generated content sharing, no ads, and no in-app purchases — expect
  **Everyone / PEGI 3**
- Category: **Tools** (not Education — it is a utility)

**Apple App Store**
- 6.7" and 6.5" iPhone screenshots; 12.9" iPad screenshots (required if iPad is
  a supported device, which it is)
- Privacy nutrition labels: **Data Not Collected**
- Age rating questionnaire (expect 4+)
- Export-compliance: the app contains **non-exempt cryptography it implements
  itself** — the hand-rolled OPC UA stack (RSA-2048, AES-256-CBC, SHA-256/HMAC,
  RSA-OAEP; see `SECURITY_AND_SAFETY.md` §OPC UA Security). This is **not** the
  usual "only uses HTTPS" exemption. Answering the export questions requires
  care and may require a self-classification report / annual report — flag it
  loudly in SHIPPING.md as a step to research before the first submission
- Review notes: explain that the app *hosts servers* and that the reviewer will
  see a **Local Network permission prompt**; provide a one-line "how to see it
  work" (open Gateway → start Modbus TCP → the status card reads Running)

**Listing copy guardrail (both stores).** `SECURITY_AND_SAFETY.md`'s
non-safety disclaimer is a **listing asset**: lift its "NOT FOR PRODUCTION
CONTROL OR MACHINE SAFETY / no SIL or IEC 61508 certification / non-deterministic
scheduling / no substitute for hardwired safety circuits" wording into the store
description. Presenting an uncertified simulator as a PLC is both a review risk
and a real-world liability; the disclaimer already exists and is well-written —
use it rather than paraphrasing.

---

## §9 — What to do with the two stale prior specs

**Decision: annotate both, rewrite neither.** Specs are a historical record;
editing their bodies to match today falsifies that record. But leaving a spec
that says "add `INTERNET`" with no indication it never happened is exactly the
trap this workstream fell into.

Neither prior spec has a `## Changelog` section (that convention post-dates
them), so add a single bolded line to each header block, immediately under
`**Status:**`:

- `2026-07-06-native-app-readiness-design.md`:
  > **Superseded in part (2026-08-08):** this workstream **shipped**. Its
  > "Not in scope of this readiness pass" list — on-device network
  > permissions, signing, store assets — is now owned by
  > `2026-08-08-store-readiness-design.md`.

- `2026-07-09-mobile-polish-haptics-native-readiness-design.md`:
  > **Superseded in part (2026-08-08):** **Part A (haptics) shipped. Part B
  > (native mobile readiness — network permissions, release signing scaffold,
  > `docs/mobile-packaging.md`) was never planned and never executed.** Part B
  > is superseded by `2026-08-08-store-readiness-design.md`, which re-derives
  > it from a fresh audit; do not implement from this document.

---

## §10 — Deferred (recorded in `docs/DEFERRED.md`)

New rows, under a new section **"Store readiness (spec 2026-08-08)"**:

| Item | Priority | Notes |
|---|---|---|
| Google Play / App Store submission | user-owned | Developer accounts ($25 one-off / $99-yr), keystore + certificate generation, provisioning profiles, listing copy, screenshots, uploads. Claude cannot and will not create accounts, hold signing material, or upload. The repo is made ready; submission is the user's. |
| iOS code-signed CI build | near-term | The CI iOS job is `--no-codesign`. Signing needs an Apple account, a distribution certificate, and a provisioning profile in CI secrets — add the secret-gated step the Android job already models, once an account exists. |
| iOS multicast entitlement (BACnet broadcast I-Am) | later | `com.apple.developer.networking.multicast` requires an Apple application against a paid account. Without it the BACnet host still binds 47808 and answers directed Who-Is on iOS; only the unsolicited startup broadcast is lost (already best-effort and logged, `bacnet_host.dart:245-255`). |
| True background execution | later | An Android foreground service (with its persistent notification and Play policy justification) and iOS `BGTaskScheduler` would let hosting survive backgrounding. The lifecycle setting decides whether to *pause cleanly*, not how to *keep running*. Substantial platform-channel work, real store-policy risk. |
| macOS App Store / notarised DMG | later | Needs an Apple account, hardened runtime review against the entitlements in §1.3, and notarisation. |
| Linux packaging | later | Flatpak/Snap/AppImage/.deb from `flutter build linux --release` on a Linux host. |
| Windows Store (MSIX) | later | `msix` package + a Microsoft Partner account. |
| `ACCESS_NETWORK_STATE` + connectivity indicator | later | Not declared today because nothing reads connectivity (§1.1). If a "no network / Wi-Fi off" banner is ever built, it needs the permission and the `connectivity_plus` dependency. |
| CI code-coverage reporting | later | The `gate` job runs `flutter test` without `--coverage`; wiring coverage upload is orthogonal to shipping. |

---

## §11 — Risks a reviewer should attack

**R1 — The lifecycle state machine is the only place this spec can produce a
*worse* app than today.** Everything else is additive config. A wrong transition
(suspending on `inactive`) closes every socket when a user swipes down the
notification shade; a missed resume leaves the app silently dead-looking with a
Run indicator that lies. Attack: is `hidden` really safe to treat as flush-only
on Android, where some OEM skins deliver `hidden` without a following `paused`?
If so, the app stays running while backgrounded on those devices — the OFF
behaviour, which is a *degradation to today*, not a regression, but the banner
would never fire. Consider whether L4 should also suspend on Android
specifically.

**R2 — The manual-toggle race (§2.4) has an 18-call-site fan-out.** The
generation counter is correct in the abstract, but its correctness depends on a
one-line addition to each of eighteen near-identical methods in a 5739-line
file. G8's source-grep is a guard, not a proof — it checks the *string* is
present, not that it is called before the start/stop rather than after (where
it would bump the generation the resume loop is about to check anyway, which is
harmless, versus after an `await`, which would not be). Attack: is a
`_resumeInProgress` flag that simply disables the Gateway's start/stop buttons
for the duration of the resume loop (typically < 1 s) a smaller, more obviously
correct design than a generation counter plus eighteen callbacks? It costs a
brief disabled-button flicker and touches two files instead of two-plus-eighteen.

**R3 — CI cannot verify the thing this spec is for.** Every functional change in
§1 only manifests in a *release build on a real device*: `INTERNET` matters only
in the release manifest merge, `NSLocalNetworkUsageDescription` only on physical
iOS hardware, the macOS entitlements only under a sandboxed signed build. The
guard tests assert *presence of text*, not *effect*. The one real end-to-end
proof available on this dev machine is the Android release-APK-on-device Modbus
connection in §7 — if that is skipped, the headline blocker is closed on
paper only. Attack: is there a cheaper on-device Android proof worth making
mandatory in the plan (e.g. a scripted `adb install` + loopback Modbus poll)?

Lesser risks worth a look: the §4.3 `ConstrainedBox` change alters
`InteractiveViewer`'s pan extent for small content across **every** canvas editor
(LD, FBD, SFC, HMI), not just the one that reported the bug; the §1.4 Gradle
block runs on AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20, where
`signingConfigs { create("release") { … } }` inside a conditional is valid but
less-travelled than the doc-standard unconditional form; and the `0.9.0+2` bump
is irreversible upward per store once uploaded.

---

## §12 — Execution shape (for the plan)

Six tasks. T1 is the blocker-closer and should land first and alone; T3 is the
risky one.

| # | Task | Model · Effort | Depends on | Notes |
|---|---|---|---|---|
| T1 | **Platform config + signing scaffold + guard tests** — §1.1-§1.4, §1.5's version/manifest/index edits, `key.properties.example`, root `.gitignore`, `platform_config_guard_test.dart` G1-G7 | sonnet · medium | — | Mechanical and exactly specified; the whole value is in getting the literal strings right, which the guard test then pins. Closes the headline blocker on its own. |
| T2 | **UX polish** — §4.1-§4.4, the four DEFERRED rows, plus browser verification at all three viewports | sonnet · medium | — | Independent of everything else; can run in parallel with T1. Four small, well-localised edits with existing tests to keep green. |
| T3 | **App lifecycle** — §2 in full: the observer, the state machine, suspend/resume, the setting + dialog + persistence, the resume banner, `kLogSourceLifecycle`, the `GatewayScreen` callback (+ G8), `lifecycle_pause_test.dart` L1-L11, `refresh_rate_pref_test.dart` S1-S5 | **opus · high** | T1 (for G8's home in the guard file) | The risky one. Touches a 3487-line shell's timer core and a 5739-line screen's eighteen toggles; eleven behavioural cases; R1 and R2 both live here. Should be reviewed as its own PR. |
| T4 | **CI workflow** — §3, `.github/workflows/ci.yml`, verified by an actual run on the branch | sonnet · medium | T1 (Android job needs the signing block), T3 (gate must pass the new tests) | Iterative by nature — expect two or three pushes to get the runner matrix and the secret-detection step right. Verify the `gate`, `ios`, and `windows` jobs go green with **no** secrets configured. |
| T5 | **Docs** — §8: SHIPPING.md overhaul incl. the §8.2 asset checklist, new `docs/mobile-packaging.md`, PROJECT_BRIEF fix, bacnet/trends notes, DEFERRED rows (close 4, add 9), the §9 supersession banners | sonnet · medium | T1-T4 | Written last so it documents what actually shipped, including the re-derived test count. |
| T6 | **Knowledge base + final verification** — §8.1's `CL-` entry + `canonical-manifest.json`, then the §7 matrix end to end: full suite, analyze, Android release build **both ways**, on-device Modbus smoke, Windows build, browser verification | sonnet · medium | T1-T5 | The verification-before-completion gate. No "done" claim before the Android-on-device Modbus connection is observed (R3). |

T1 and T2 are independent and should be dispatched in parallel. T3 is a solo
run. T4 needs T1 and T3 landed. T5 and T6 are sequential closers.
