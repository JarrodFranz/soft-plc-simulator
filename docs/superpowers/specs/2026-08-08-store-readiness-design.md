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
- 2026-08-08 — applied design-review fixes (verdict NEEDS UPDATES). §2 reworked
  around the verified host reality — **8 uniform start/stop hosts + MQTT
  special** (connect/disconnect, password lives only in un-persisted
  `GatewayScreen` state, so resume does **not** reconnect); `_LifecycleHost`
  now carries start/stop **closures**. The suspend flush is now a real
  awaited `flushPendingAutosaveNow()` (B2). The manual-toggle race is resolved
  by the **binding R2 ruling**: a shell-owned `_resumeInProgress` lock surfaced
  as one `hostsBusy` bool wrapping the Gateway card body in a single
  `AbsorbPointer` — `onManualHostToggle`, `_resumeGeneration`, and guard G8 are
  **deleted**. CI job gate switched to `vars.` (B3); the "unsigned"→"debug-signed"
  contradiction corrected everywhere with conditional artifact names (B4).
  R1 hidden-suspend mitigation **rejected** (M8), R3 Android on-device proof made
  mandatory in T6, plus M5/M6/M7/M9/M10 and minors m11-m17. Execution graph:
  T1/T2/T3 now parallel, §4 (T2) lands as its own PR.

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
| N4 | **Every signing-secret-dependent step degrades gracefully.** CI signs with the upload key when secrets are configured and produces a **debug-signed (not store-uploadable)** artifact when they are not; Gradle signs when `key.properties` exists and falls back to the debug key when it does not. "Debug-signed" ≠ "unsigned" — see B4 (§3): a debug-signed AAB is Play-rejected and its per-run key is not upgrade-compatible, so that artifact is sideload/smoke only. | There are no store accounts yet. A red CI on a fresh clone would be a permanent false alarm; a build that *cannot* run without secrets would block all local release smoke-testing. |
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
                // require(...) per property (m12): a half-filled key.properties
                // otherwise yields a null storeFile and a deep, opaque AGP 9
                // failure at assemble time. Fail loudly here with the missing key.
                fun req(k: String): String = keystoreProperties.getProperty(k)
                    ?: error("key.properties present but missing '$k' — fill it in or delete the file to fall back to debug signing.")
                keyAlias = req("keyAlias")
                keyPassword = req("keyPassword")
                storeFile = file(req("storeFile"))
                storePassword = req("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Debug-signed fallback (NOT unsigned, NOT store-uploadable):
                // debug keys keep `flutter build apk --release` working without
                // secrets for sideload/smoke. A store AAB requires key.properties.
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
ignored):

```gitignore
*.keystore
key.properties
```

**No `!**/key.properties.example` negation (m11).** It would be dead: the
gitignore pattern is the bare filename `key.properties`, which never matches
`key.properties.example` in the first place (gitignore matches full path
segments, not prefixes), so the example file is already tracked with nothing to
un-ignore. Adding the negation just implies a conflict that does not exist.

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
| The nine hosts | `:135-143` | `late final`, owned by the shell, passed into `GatewayScreen`; 8 listening + MQTT (see above) |
| `dispose()` | `:279-294` | cancels all timers, disposes all nine hosts |
| Settings keys | `:63,:72` | `ui_refresh_hz`, `haptics_enabled` |
| `applyRefreshHz` / `applyHapticsEnabled` | `:561`, `:537` | `@visibleForTesting`, best-effort persist |
| `_flushPendingAutosave()` | `:1103-1108` | `void`; calls `_flushActiveEditor()` (`:1096`) then `unawaited(_runAutosave())` — **fire-and-forget, does not complete** (see B2 / §2.2) |
| `_runAutosave()` | `:1049` | `Future<void>` — the actual persist |
| Settings load | `:328-338` | inside `_boot()`, reusing the `prefs` handle |

**Host API: 8 uniform + MQTT special (verified).** The eight *listening* hosts
(OPC UA, Modbus, DNP3, EtherNet/IP, S7, FINS, SLMP, BACnet) share one shape —
`ChangeNotifier`, a `<Name>HostStatus get status` getter over an enum whose
running member is `running`, `Future<void> start(PlcProject Function() projectProvider)`,
`Future<void> stop()`. **MQTT is different and must not be forced into that
mould:**

- `MqttHost.connect(PlcProject Function() projectProvider, {required String password})`
  (`mqtt_host.dart:348`) — not `start`, and it takes a **broker password**.
- `MqttHost.disconnect()` (`:965`) — not `stop`.
- `enum MqttHostStatus { stopped, connecting, running, error }`
  (`:130`) — it has a **`connecting`** member the other eight lack.
- **The password lives only in un-persisted UI state.** `GatewayScreen._mqttPassword`
  (`:193`) is a plain `String` fed from a `TextField` (`:5374`), reset to `''`
  on every project change (`:348`), and **never persisted** anywhere. The shell
  does not have it, and `GatewayScreen` may be unmounted while the app is
  backgrounded. **The shell therefore cannot reconnect MQTT after a lifecycle
  stop** — this is the crux of §2.4's MQTT handling.

`GatewayScreen` drives the ten controls through **sixteen** uniform one-line
`_(start|stop)*Hosting` helpers for the eight listening hosts
(`gateway_screen.dart:572-646`, e.g. `_startHosting` →
`widget.host.start(() => widget.currentProject)`) **plus** `_connectMqtt`
(`:647`) / `_disconnectMqtt` (`:651`). MQTT's helpers do not match a
`*Hosting` pattern — a fact that mattered to the deleted guard G8 and no longer
matters under the R2 ruling (§2.4).

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

**Why this exact set, and why `hidden` is flush-only (M8).** Flutter does **not**
walk these states one-way; it traverses `hidden` in **both** directions on
every app-switch and every transient interruption
(`resumed ↔ inactive ↔ hidden ↔ paused`). Suspending on `hidden` would
therefore stop and restart every host on *every* app-switch — the thrash the
`inactive` row already warns about, one state deeper. The chosen mapping
(`resumed` = resume, `inactive` = no-op, `hidden` = flush-only, `paused` =
suspend, `detached` = unconditional stop) is the correct one; it is recorded
here so it is not "optimised" into a hidden-suspend later. Two consequences to
document rather than fix:

- The **flush also runs on the foreground path** (`hidden` on the way back up).
  That is benign and idempotent — with nothing pending it is a no-op, which
  case L4 asserts.
- On **Android, `detached` followed by re-attach to a new `Activity`** (e.g. a
  config-change teardown the OS did not route through `dispose`) returns with
  the hosts stopped and **no resume banner** (no suspend recorded ⇒ nothing to
  resume). This is logged under `kLogSourceLifecycle` and documented in
  `docs/mobile-packaging.md` as a known, rare edge; the user restarts hosts
  from the Gateway.

**Platform gate (binding).** Suspend/resume applies only when
`defaultTargetPlatform` is `TargetPlatform.android` or `TargetPlatform.iOS`
**and** `!kIsWeb`. On Windows/macOS/Linux a minimised or unfocused window
*should* keep hosting — that is the whole point of the desktop build — and
`hidden` there is a normal minimise, not a background. The setting's UI is
disabled with an explanatory subtitle on those platforms (§2.5).

**New state fields** on `WorkspaceShellState`:

```dart
/// True between a lifecycle suspend and its matching resume. Consulted by
/// [_startScanLoop]'s free-run re-arm guard (§2.2 step 5) so a suspend
/// genuinely stops the chain rather than letting it re-arm itself.
bool _lifecycleSuspended = false;

/// Hosts that were running at suspend time and are therefore eligible to be
/// restarted on resume. A host the user stopped manually beforehand is not in
/// this set, so it stays stopped (N6). Ids per the table below.
final Set<String> _resumeHostIds = <String>{};

/// Guards against overlapping suspends: `hidden` then `paused` arrive
/// back-to-back, and each dispatches an async `_onSuspend`. Set at handler
/// entry (§2.2 step 1), cleared in a `finally`.
bool _suspendInFlight = false;

/// True while the resume restart loop is in flight. Surfaced to GatewayScreen
/// as `hostsBusy` so its protocol-card body is wrapped in a single
/// AbsorbPointer — the user cannot toggle a host mid-resume, which ELIMINATES
/// the manual-toggle race rather than detecting it (R2 ruling, §2.4). Always
/// cleared in a `finally`.
bool _resumeInProgress = false;
```

Hosts are addressed by a stable string id (`'opcua'`, `'modbus'`, `'dnp3'`,
`'enip'`, `'s7'`, `'fins'`, `'slmp'`, `'bacnet'`, and `'mqtt'`) through one
private table so the fan-out is written once. Each entry carries **start/stop
closures**, not a `start`/`stop` method reference — this is what lets MQTT
(`connect`/`disconnect`, different signature) sit in the same list with no
call-site special-casing:

```dart
/// A host as the lifecycle machine sees it: a stable id, a display name, a
/// live "is it running?" probe, and start/stop CLOSURES. The eight listening
/// hosts wrap start()/stop(); MQTT wraps connect(..., password: …)/disconnect()
/// -- see the `mqtt` entry, whose `start` closure is deliberately a no-op that
/// records a warning, because the shell has no broker password to reconnect
/// with (§2.4).
class _LifecycleHost {
  final String id;
  final String displayName;
  final bool Function() isRunning;      // status == running (MQTT: running || connecting)
  final Future<void> Function() start;  // resume path
  final Future<void> Function() stop;   // suspend path
  const _LifecycleHost(...);
}

List<_LifecycleHost> get _lifecycleHosts => [
  _LifecycleHost('opcua', 'OPC UA',
      () => _opcuaHost.status == OpcUaHostStatus.running,
      () => _opcuaHost.start(() => _activeProject),
      () => _opcuaHost.stop()),
  // … the other seven listening hosts, identically shaped …
  _LifecycleHost('mqtt', 'MQTT',
      () => _mqttHost.status == MqttHostStatus.running
          || _mqttHost.status == MqttHostStatus.connecting,
      () async => _logger.warn(kLogSourceLifecycle,
          'MQTT was disconnected on background; not auto-reconnected '
          '(broker password is not stored). Reconnect from the Gateway.'),
      () => _mqttHost.disconnect()),
];
```

### §2.2 Suspend sequence

`didChangeAppLifecycleState(state)` is a **synchronous `void`** — it cannot
`await`. So the handler does the minimum synchronously and dispatches the rest
to a `Future<void> _onSuspend({required bool flushOnly})`, whose returned future
the handler **retains** (a field) so tests can await it; production fire-and-
forgets it but the *flush inside it is itself awaited before any host is
touched* (B2). Ordered, idempotent, individually failure-tolerant — the OS
gives a backgrounding app a short, unspecified budget and may kill it
mid-sequence.

1. **Re-entrancy guard at the very entry.** If a suspend is already in flight
   (`_suspendInFlight`), return immediately. This is the **first** statement, not
   a mid-sequence check — `hidden` then `paused` arrive back-to-back and must not
   run two overlapping suspends. Set `_suspendInFlight = true` and clear it in a
   `finally`.
2. **Flush pending writes — ALWAYS, regardless of the setting, and AWAITED.**
   `await flushPendingAutosaveNow()` (the new method, §2.2a) as the **first
   real action**, before any host is stopped. The existing
   `_flushPendingAutosave()` (`workspace_shell.dart:1103-1108`) is `void` and
   ends in `unawaited(_runAutosave())` — it *schedules* the write and returns;
   iOS can freeze the process before it lands, so on its own it **does not fix
   the data-loss bug**. Awaiting the real future does. Not gated on the setting
   — it is a durability measure, not automation control.
3. If `flushOnly` is true (the `hidden` path), or the setting is off, or the
   platform is not mobile, **stop here** — the flush was the whole job.
4. `_lifecycleSuspended = true;`
5. Capture `_resumeHostIds` from the `_lifecycleHosts` table's live
   `isRunning()` probe (MQTT counts as capturable when `running` **or**
   `connecting`). A host the user already stopped is not captured (N6).
6. Halt the scan loop. Cancel `_scanTimer` and `_supervisorTimer`, and set
   `_lifecycleSuspended` (already done in step 4) so the loop cannot re-arm
   itself. **`isRunning` is deliberately left untouched** — it is the user's
   Run/Pause *intent* and must be exactly what it was on return. The three
   guards in `_startScanLoop()` change as (M10) — quoting the current source:
   - free-run inner early-return `if (!isRunning || _faulted) {` (`:439`)
     becomes `if (!isRunning || _faulted || _lifecycleSuspended) {`
   - free-run outer re-arm `if (isRunning && !_faulted) {` (`:448`) becomes
     `if (isRunning && !_faulted && !_lifecycleSuspended) {`
   - the fixed-mode `Timer.periodic` body `if (isRunning && !_faulted) {`
     (`:452`) becomes `if (isRunning && !_faulted && !_lifecycleSuspended) {`
7. `_uptime.stop();` — `System.Uptime` means "time the PLC was actually
   scanning", not wall-clock including a suspended night. `Stopwatch` preserves
   elapsed across stop/start, so nothing is lost.
8. Stop the captured hosts via their `stop` **closures** (listening hosts →
   `stop()`, MQTT → `disconnect()`), each in its own `try`/`catch`, awaited
   together under a bounded overall timeout (**2 s**) so a wedged socket cannot
   consume the whole background budget. Timeout is logged, not thrown.
9. Log one `INFO` line under `kLogSourceLifecycle` naming the count and ids,
   e.g. `Backgrounded: scan paused, 3 host(s) stopped (opcua, modbus, mqtt).`

### §2.2a `flushPendingAutosaveNow()` (the B2 fix)

A new method on `WorkspaceShellState`, alongside the existing
`_flushPendingAutosave()`:

```dart
/// Like [_flushPendingAutosave], but RETURNS the autosave future so a caller
/// can await the write actually landing (the lifecycle suspend path must, so
/// an edit made in the last 800ms before iOS freezes the process is durable).
/// The void [_flushPendingAutosave] is kept for the fire-and-forget callers
/// (project switch/close) that don't need to block on completion.
@visibleForTesting
Future<void> flushPendingAutosaveNow() async {
  _flushActiveEditor();
  if (_autosaveTimer == null || !_autosaveTimer!.isActive) return;
  _autosaveTimer!.cancel();
  await _runAutosave();
}
```

The existing `_flushPendingAutosave()` is refactored to
`unawaited(flushPendingAutosaveNow())` so the two cannot drift.

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

### §2.4 Restart, and the manual-toggle race (N6) — the R2 ruling

**The race, and why the resume LOCK (not a generation counter) is the fix.**
The window is: the shell is part-way through restarting the captured hosts when
the user taps a host's start/stop on the Gateway. A generation counter *detects*
that (bump on manual toggle, re-check each iteration) but then **over-reacts** —
one tap silently aborts the restart of *every remaining* host — and it costs a
one-line addition to sixteen near-identical helpers plus two more for MQTT, two
of which the old source-grep guard (G8) could not even see (`_connectMqtt`/
`_disconnectMqtt` don't match `*Hosting`). Per the binding R2 ruling this whole
approach is **replaced**:

> **The shell owns `_resumeInProgress`, surfaces it to `GatewayScreen` as a
> single `bool hostsBusy`, and `GatewayScreen` wraps its protocol-card body in
> ONE `AbsorbPointer(absorbing: hostsBusy, …)` with a "Resuming…" affordance.**
> While the resume loop runs, **no toggle is possible** — the race is
> *eliminated*, not detected. `onManualHostToggle`, `_resumeGeneration`, and
> guard G8 are **deleted**.

- **Churn:** ~10 lines across 2 files — one `bool` constructor param + one
  `AbsorbPointer` wrap in `gateway_screen.dart`; one flag + its `setState`
  toggles in `workspace_shell.dart` — versus 18 hand-edits.
- **Testability:** pump the shell, drive `paused → resumed`, assert the Gateway
  toggles are non-interactive during the loop and interactive after
  (`AbsorbPointer.absorbing` via the widget tree). Deterministic, no source-grep.
- **Defence in depth:** the per-host **"skip `H` if `H.isRunning()` /
  `H.status != stopped`"** check below is *kept* — belt to the AbsorbPointer's
  braces, and it also covers the MQTT-already-connecting case.

**The restart loop** (`Future<void> _resumeRestartHosts()`), MANDATORY hard
bounds so a wedged bind can never leave the Gateway permanently frozen:

```dart
_resumeInProgress = true;
setState(() {});                     // Gateway rebuilds with hostsBusy = true
try {
  for (final h in _lifecycleHosts) {
    if (!_resumeHostIds.contains(h.id)) continue;     // wasn't running at suspend
    if (h.isRunning()) continue;                       // already up — skip (defence)
    try {
      await h.start().timeout(const Duration(seconds: 2));   // per-host bound
    } catch (e) {
      // port taken / permission denied / MQTT no-op-warn — logged, NAMED in the
      // resume banner, does NOT abort the remaining hosts.
      _restartFailures.add(h.displayName);
      _logger.warn(kLogSourceLifecycle, '…');
    }
  }
} finally {
  _resumeInProgress = false;
  if (mounted) setState(() {});      // Gateway re-enabled, ALWAYS
}
```

plus an **overall 5 s** bound (`.timeout` around the whole loop, or a deadline
check per iteration) so eight slow-but-not-wedged binds cannot compound past the
budget. Sequential, not parallel: eight simultaneous binds — one of which loads
and parses an RSA-2048 certificate in `OpcUaHost.start()` — on a just-woken
phone is a needless thundering herd, and sequential order gives deterministic
support logs.

**MQTT never reconnects here.** Its `start` closure is the no-op warning from
§2.1 (the shell has no broker password — §2.0/B1), so if MQTT was connected at
suspend it is captured, disconnected on suspend, and on resume produces the
WARN and a banner line telling the user to reconnect from the Gateway (§2.6). It
never counts as a restart failure — it is an expected, explained non-reconnect.

**`GatewayScreen` change (the whole R2 surface).** One new field, one wrap:

```dart
/// True while the shell is mid-resume restarting hosts (store-readiness §2.4).
/// The protocol-card body is wrapped in AbsorbPointer(absorbing: hostsBusy) so
/// the user cannot toggle a host during the restart loop — the manual-toggle
/// race is eliminated at the source. A brief (<1s) disabled flicker on
/// foreground when hosts restart is accepted; it affects the Gateway screen
/// only. `onManualHostToggle`/generation-counter approaches are NOT used.
final bool hostsBusy;
```

The sixteen `*Hosting` helpers and `_connectMqtt`/`_disconnectMqtt` are **left
exactly as they are** — no per-helper edits at all.

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

**Dialog** — `softplc_settings_dialog.dart` (M9).
`SoftPlcSettingsResult` gains `final bool pauseInBackground;`;
`SoftPlcSettingsDialog` gains `initialPauseInBackground`. The dialog has
**one** `SwitchListTile` today (haptics), so the new one is the **second**, not
"third", appended below it. The file already carries a landscape-height comment
warning that a tall dialog pushes controls below the fold, so the subtitle is
kept to **≤ 2 lines** — the full per-platform reality lives in
`docs/mobile-packaging.md`, not the dialog. Copy (exact):

```
title:    Pause automation when app is in background
subtitle (mobile, enabled):
          On: hosts close cleanly and the scan pauses when you leave the app,
          then resume on return. Off: the OS decides (iOS suspends anyway).
subtitle (desktop/web, switch disabled):
          Mobile only — a desktop window keeps scanning and hosting.
```

The per-platform reality is stated *in the dialog* in brief — this is the one
place a user looks when a client drops on lock-screen — with the full detail in
the packaging doc.

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
- **MQTT was connected at suspend** (its non-reconnect is *not* a failure, but
  the user must be told): append
  `MQTT was disconnected — reconnect from the Gateway (broker password isn't stored).`
  to whichever line above applies. MQTT is excluded from the "N of M restarted"
  count entirely, since it is never a restart candidate.
- Nothing was running at suspend time (and MQTT was not connected): **no
  snackbar at all** (nothing to report; an unconditional toast on every
  app-switch would be noise).

### §2.7 Logging

Per the repo's protocol-logging rule, a new source constant is added to
`mobile/lib/models/app_log.dart` **and** to `kAllLogSources` (the existing guard
test in `app_log_test.dart` enforces the pair):

```dart
const String kLogSourceLifecycle = 'Lifecycle';
```

Levels: `INFO` for each suspend and resume summary; `WARN` for a host that
failed to stop within the timeout, failed to rebind on resume, or MQTT's
expected non-reconnect; `DEBUG` for the per-host stop/start transitions and the
`detached`-without-suspend re-attach case (§2.1 M8).

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
throttle them by editing one setting rather than restructuring.

**Use a repository variable, NOT `env:` (B3).** The `env` context is **not
available** in a job-level `if:` (`jobs.<id>.if` is evaluated before the job's
environment exists), so an `env:`-based gate silently never skips. Use a
repo/environment **variable** — `vars` *is* available at job level:

```yaml
# In repo settings -> Secrets and variables -> Actions -> Variables, optionally
# set BUILD_PLATFORM_ARTIFACTS = 'false' to skip the macOS/Windows runners (e.g.
# if this repo ever becomes private, where macOS bills at a 10x minute
# multiplier). Absent / anything-but-'false' => the jobs run.
jobs:
  ios:
    if: ${{ vars.BUILD_PLATFORM_ARTIFACTS != 'false' }}
    # …
  windows:
    if: ${{ vars.BUILD_PLATFORM_ARTIFACTS != 'false' }}
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

| Job | Runner | Needs | Steps | Artifact (`upload-artifact@v4` archives the dir/files) |
|---|---|---|---|---|
| `gate` | `ubuntu-latest` | — | `flutter pub get`; `flutter analyze` (fails on any issue — the repo's standing "no analyze warnings" rule); `flutter test` | — |
| `android` | `ubuntu-latest` | `gate` | Java 17; detect keystore; write `key.properties` **if secrets present**; `flutter build appbundle --release`; `flutter build apk --release` | `android-release-signed` **or** `android-release-debugsigned` (name chosen by the detect step — see B4) — the `.aab` + `.apk` paths |
| `ios` | `macos-latest` | `gate` | `flutter build ios --release --no-codesign` | `ios-release-unsigned-noninstallable` — `build/ios/iphoneos/Runner.app` (see m13) |
| `windows` | `windows-latest` | `gate` | `flutter build windows --release` | `windows-release` — the `build/windows/x64/runner/Release` **directory** |

All jobs `defaults: run: working-directory: mobile` (every `flutter` command in
this repo runs from `mobile/`).

**No manual `zip` steps (M6).** `actions/upload-artifact@v4` zips whatever path
(file or directory) it is given; a hand-rolled `zip`/`Compress-Archive` is
redundant and, on `windows-latest` (which defaults to **PowerShell**, where
`zip` does not exist), actively wrong. Point `upload-artifact` at the build
output directory directly on all three platform jobs.

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
            echo "artifact=android-release-signed" >> "$GITHUB_OUTPUT"
          else
            echo "present=false" >> "$GITHUB_OUTPUT"
            echo "artifact=android-release-debugsigned" >> "$GITHUB_OUTPUT"
            echo "::warning::No ANDROID_KEYSTORE_BASE64 secret — building DEBUG-SIGNED. This artifact is for sideload/smoke only and CANNOT be uploaded to Play (debug key; a fresh key each run is not upgrade-compatible)."
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

**"debug-signed", not "unsigned" (B4).** The no-secrets fallback produces a
build signed with the **debug** key (§1.4's `signingConfigs.getByName("debug")`)
— it is *signed*, just not with an upload key. That distinction is load-bearing:
a debug-signed AAB is **rejected by Play**, and because CI has no persistent
keystore it would sign each run with a *different* debug key (not
upgrade-compatible). So the no-secrets Android artifact is explicitly for
**sideload / on-device smoke only, never store upload** — which is exactly what
the `android-release-debugsigned` artifact name and the `::warning::` above
communicate. Wherever "unsigned" appeared for the Android fallback, read
"debug-signed (not store-uploadable)". (iOS `--no-codesign` genuinely *is*
unsigned — different case, below.)

**iOS is intentionally unsigned and non-installable (m13).** `--no-codesign`
needs no Apple account, certificate, or provisioning profile. The resulting
`Runner.app` is **not installable anywhere** (no signature, no provisioning) —
its only value is proving the iOS toolchain **compiles this source tree** (the
job's green/red is the signal). It is uploaded under a name that says so
(`ios-release-unsigned-noninstallable`) so nobody downloads it expecting to run
it; dropping the upload entirely is a defensible alternative. Adding real
codesigning is a later, secret-gated step exactly like Android's.
**Budget a CocoaPods retry:** `mobile/ios/Podfile` does **not** exist in the
repo, so the first CI run hits the first-run `pod install` path — flaky on cold
runners; wrap the iOS build in a one-retry step.

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

**`MenuAnchor` does not inherit the old width/colour (m15).** `DropdownButton`'s
`isExpanded: true` (full-width) and `dropdownColor: 0xFF1E293B` do **not** carry
over — a bare `MenuAnchor` panel is content-width and theme-surface-coloured.
Reproduce both explicitly via `MenuStyle(backgroundColor:
WidgetStatePropertyAll(Color(0xFF1E293B)), minimumSize:
WidgetStatePropertyAll(Size(<anchor width>, 0)))`, sizing the panel to the
anchor's measured width (a `LayoutBuilder` around the anchor, or the
`MenuAnchor` builder's constraints) so the menu still spans the header.

Existing widget tests that tap the dropdown by type must be updated to tap the
anchor; the *behaviour* under test (switching projects) is unchanged.

### §4.2 Tags & Structs FAB pinned bottom bar

**Site:** `memory_manager_screen.dart:1500-1513`, `_buildStructDefsTab()`.

Verified: this tab has its **own nested `Scaffold`** with its own
`floatingActionButton`, separate from the outer screen's FAB column at `:721`.
The change is therefore contained to this tab.

Replace the nested `Scaffold` + `FloatingActionButton.extended` with a `Column`:
the list area in an `Expanded`, and below it a pinned action surface —
`SafeArea(top: false, child: Container(padding: EdgeInsets.all(12), color: 0xFF1E293B, child: SizedBox(width: double.infinity, child: FilledButton.icon(icon: add, label: 'Add DUT'))))`.
Drop the ListView's 96 px trailing padding back to a plain
`EdgeInsets.all(16)` — nothing floats over the list any more, so the last card is
clear at **any** scroll position, which is exactly what the deferral asked for.
**The empty-state `Center(Text(...))` branch must also sit inside the
`Expanded` (m14):** in a `Column`, a bare `Center` has no bounded height and the
bottom bar would be pushed off-screen or throw an unbounded-height error. Wrap
whichever branch renders (list *or* empty-state) in the single `Expanded`, with
the bottom bar always below it — the empty state is precisely when the user most
needs the Add button visible.

### §4.3 `PannableCanvas` pointer-signal gap

**Site:** `pannable_canvas.dart:140-153` (`_onPointerSignal`, the
`if (pre == null) return;` early-out) and `:306-323` (the outer `Listener` →
`InteractiveViewer` → inner capture `Listener` → `widget.child` sandwich).

**Root cause:** the inner capture `Listener` is `HitTestBehavior.opaque` but
covers only the *child's laid-out rect*. With `constrained: false` the child is
its intrinsic size, so a viewport larger than the content has dead zones where
the capture never fires, `pre` stays null, and the wheel falls through to
`InteractiveViewer`'s own zoom.

**The naive fix is wrong at zoom < 1 (M5).** The capture `Listener` lives
**inside** the `InteractiveViewer`, so its constraints are in the child's
**canvas** coordinate space, while the viewport size (`_viewport`, already
captured by the outer `LayoutBuilder` at `pannable_canvas.dart:302`) is in
**screen pixels**. Sizing the capture layer to raw `_viewport` therefore
under-covers whenever the content is zoomed out: at the default `minScale = 0.4`
one screen pixel is 2.5 canvas units, so a viewport-sized capture layer still
leaves a dead ring and the `pre == null` fall-through persists.

**Fix:** size the min-constraints in **canvas units** by dividing the viewport
by the current scale — `_controller.value.getMaxScaleOnAxis()` (the same call
`_zoomAt` already uses at `:237`) — and rebuild when the controller changes so
the coverage tracks live zoom:

```dart
// Reuse the OUTER LayoutBuilder's _viewport (screen px); convert to canvas
// units by the live scale so the capture layer covers the viewport at ANY zoom.
// Do NOT add an inner LayoutBuilder: under constrained:false its maxWidth/Height
// are unbounded (infinity) and ConstrainedBox(minWidth: infinity) throws.
final scale = _controller.value.getMaxScaleOnAxis();
final coverW = _viewport.width  / scale;
final coverH = _viewport.height / scale;
// ConstrainedBox(minWidth: coverW, minHeight: coverH) around the capture child,
// rebuilt via an AnimatedBuilder/ListenableBuilder on _controller.
```

If tracking live zoom proves fiddly, the fallback the review accepts is to
**state the limitation honestly** — the gap closes for scale ≥ 1 only — and keep
the `pre == null` branch live rather than claiming it is unreachable. Either
way, **never** introduce an inner `LayoutBuilder` (unbounded under
`constrained: false`).

**Known side effect to verify, not hide:** enlarging the capture child changes
`InteractiveViewer`'s pan extent when content < viewport. This touches **every**
canvas editor (LD, FBD, SFC, HMI), not just the one that reported the bug.
`editor_canvas_pan_test.dart` must stay green, and the task adds one case
asserting a wheel notch over empty canvas space **pans** rather than zooming.

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
wall. `flutter test` runs with CWD = the package root (`mobile/`), reading
sources by package-relative path. The precedent is **`app_log_test.dart:208`**
(`File('lib/models/app_log.dart').readAsStringSync()`), the exact pattern this
guard extends — *not* `opcua_cert_store_test.dart`, which uses `systemTemp` and
makes no CWD assumption. Each assertion carries a `reason:` naming *what breaks*
if it fails, so a future failure explains itself.

| # | Assertion | File read |
|---|---|---|
| G1 | Contains `android.permission.INTERNET` in a `<uses-permission …/>` element | `android/app/src/main/AndroidManifest.xml` |
| G2 | Contains `<key>NSLocalNetworkUsageDescription</key>` and the `<string>` that follows it is ≥ 40 chars and mentions `local network` | `ios/Runner/Info.plist` |
| G3 | Contains both `com.apple.security.network.server` and `com.apple.security.network.client`, each followed by `<true/>` | `macos/Runner/Release.entitlements` **and** `DebugProfile.entitlements` (parameterised over both) |
| G4 | Contains `rootProject.file("key.properties")` and `signingConfigs.getByName("release")`; does **not** contain the literal `// TODO: Add your own signing config` | `android/app/build.gradle.kts` |
| G5 | `key.properties`, `*.jks`/`**/*.jks`, `*.keystore`/`**/*.keystore` are each covered by at least one of the two gitignores. **The root gitignore is `../.gitignore` relative to the package root** (it lives at the *repo* root, outside the Flutter package) — read it via that path and `reason:` it explicitly, since a run from the repo root instead of `mobile/` would resolve `.gitignore` to the wrong file. | `../.gitignore` (repo root), `android/.gitignore` |
| G6 | Neither contains the string `A new Flutter project.` | `web/manifest.json`, `web/index.html` |
| G7 | `version:` parses as `0.9.0+2` or higher (semver + build both monotonic) | `pubspec.yaml` |

**G8 is deleted.** Under the R2 ruling there is no `onManualHostToggle` and no
per-helper edit to guard; the AbsorbPointer behaviour is covered by a *widget*
test (L12 below), not a source-grep. The MQTT special-casing (§2.0/§2.4) is what
made a `*Hosting` regex blind in the first place — the ruling removes the need
for it entirely.

New file **`mobile/test/lifecycle_pause_test.dart`** — lifecycle behaviour, driven
by `tester.binding.handleAppLifecycleStateChanged(...)` against a pumped
`WorkspaceShell` with an injected in-memory `ProjectRepository` (the existing
`widget.repository` seam) and `TestWidgetsFlutterBinding.ensureInitialized()` +
`SharedPreferences.setMockInitialValues`. `debugDefaultTargetPlatformOverride`
is set to `TargetPlatform.android` for the mobile cases and restored in
`tearDown`.

Each case that involves the async suspend/resume **awaits the retained
`_onSuspend`/resume future** the handler exposes (not a bare `pump`), so
completion is deterministic.

| # | Case |
|---|---|
| L1 | `paused` with the setting ON → scan timer is not firing (`debugBuildCount`/`scanCount` frozen across a pumped 2 s) and the started host reports `stopped` |
| L2 | `resumed` after L1 → scan ticks again and the host is `running` |
| L3 | `inactive` → **nothing** changes (the "notification shade" case) |
| L4 | `hidden` with a pending edit → **the autosave write COMPLETES** (assert the repository now holds the edit, via the injected in-memory repo — not merely that `_autosaveTimer` was cancelled); scan and hosts untouched. With **nothing** pending → the flush is a no-op (covers the foreground `hidden`, M8) |
| L5 | Setting OFF → `paused` **completes the autosave write** (same repo assertion as L4) and changes nothing else |
| L6 | A host stopped **manually** before `paused` is **not** restarted on `resumed` (N6) |
| L7 | User has the scan **paused** (`isRunning == false`) before `paused`; on `resumed` it is still paused — the lifecycle never overrides Run/Pause intent |
| L8 | A listening host whose restart throws leaves the other hosts started, is named in the resume banner, and produces a `WARN` under `kLogSourceLifecycle` |
| L9 | **MQTT special (B1):** MQTT `running` (or `connecting`) at `paused` → it is `disconnect()`ed on suspend, is **not** reconnected on `resumed` (status stays `stopped`), a `WARN` is logged, and the resume banner carries the "reconnect from the Gateway" line. MQTT is excluded from the "N of M restarted" count |
| L10 | `detached` stops every running host (listening **and** MQTT) even with the setting OFF; no resume state recorded, no banner |
| L11 | `defaultTargetPlatform == windows` → `paused` is a full no-op beyond the (completed) flush |
| L12 | **R2 AbsorbPointer:** during the resume restart loop the Gateway protocol-card toggles are non-interactive (`AbsorbPointer.absorbing == true`), and interactive again once the loop's `finally` clears `_resumeInProgress`; a host whose start **wedges** past the 5 s overall bound still leaves the Gateway re-enabled (the `finally` runs) |

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
| **Android release** | `flutter build apk --release` **twice**: once with no `key.properties` (must succeed, **debug-signed** — sideload only) and once with a throwaway local keystore (must succeed, upload-key-signed — verify with `keytool -printcert -jarfile`). Then `flutter build appbundle --release`. Then the **mandatory on-device proof (R3)** below | local (Windows) |
| **Android on-device proof (R3, MANDATORY, Wi-Fi-free)** | `adb install -r` the release APK to a USB device; `adb forward tcp:5020 tcp:502`; from the Windows Python probe lane (`mobile/tool/py/`, the pattern in `tool/enip_e2e.sh`) poll Modbus over the forwarded port. **Without `INTERNET` the bind throws and the host never reaches `running` — the bind IS the proof; the poll confirms data flow.** No Wi-Fi/LAN needed (USB `adb forward`), so it runs on any dev machine | local (Windows) |
| **Windows desktop** | `flutter build windows --release` + launch; confirm a host still runs while the window is minimised (§2.1's desktop gate) | local |
| **Web** | The repo's headless-Playwright loop (`scripts/serve-web.sh --build` + screenshots at 1440×900 / 768×1024 / 390×844) for the §4 UX changes — the dropdown, the DUT bottom bar, the FBD lane, and the canvas wheel. **Plus the SoftPLC Settings dialog with the new toggle at 390×844 and a landscape phone viewport (844×390)** to confirm the second `SwitchListTile` and its ≤2-line subtitle fit without pushing controls below the fold (M9). All must pass browser verification per CLAUDE.md | local |
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
| MQTT broker password persisted for lifecycle resume | near-term | Today the broker password lives only in un-persisted `GatewayScreen` state (`_mqttPassword`, reset on project change, never stored), so the shell cannot reconnect MQTT after a lifecycle pause (§2.0/§2.4) — it disconnects on background and tells the user to reconnect from the Gateway. Persisting it to platform **secure storage** (`flutter_secure_storage` — Keychain / Keystore, never plain `SharedPreferences` or project JSON) would let resume reconnect MQTT like the eight listening hosts. New dependency + a security review of where the secret lives; deferred deliberately. |
| True background execution | later | An Android foreground service (with its persistent notification and Play policy justification) and iOS `BGTaskScheduler` would let hosting survive backgrounding. The lifecycle setting decides whether to *pause cleanly*, not how to *keep running*. Substantial platform-channel work, real store-policy risk. |
| macOS App Store / notarised DMG | later | Needs an Apple account, hardened runtime review against the entitlements in §1.3, and notarisation. |
| Linux packaging | later | Flatpak/Snap/AppImage/.deb from `flutter build linux --release` on a Linux host. |
| Windows Store (MSIX) | later | `msix` package + a Microsoft Partner account. |
| `ACCESS_NETWORK_STATE` + connectivity indicator | later | Not declared today because nothing reads connectivity (§1.1). If a "no network / Wi-Fi off" banner is ever built, it needs the permission and the `connectivity_plus` dependency. |
| CI code-coverage reporting | later | The `gate` job runs `flutter test` without `--coverage`; wiring coverage upload is orthogonal to shipping. |

---

## §11 — Risks a reviewer should attack

**R1 — The lifecycle state machine is the only place this spec can produce a
*worse* app than today** (mitigation for the `hidden`-suspend idea **rejected**,
M8). Everything else is additive config. A wrong transition (suspending on
`inactive`) closes every socket when a user swipes down the notification shade.
The review examined whether `hidden` should also suspend (some OEM skins were
posited to deliver `hidden` without a following `paused`) and **rejected it**:
Flutter traverses `hidden` in **both** directions on every app-switch and every
transient interruption (`resumed ↔ inactive ↔ hidden ↔ paused`), so suspending
there would stop and restart all nine hosts on *every* app-switch — the exact
thrash the design avoids. The chosen set (§2.1) is correct and is now recorded
as such; the residual on those hypothetical OEMs is that the app keeps hosting
while backgrounded (the OFF behaviour — a degradation to today, not a
regression). What remains for the reviewer: confirm the §2.1 mapping against the
current Flutter `AppLifecycleState` semantics on a real Android build, and that
the `detached`→re-attach edge (M8) is only logged, never banner-spammed.

**R2 — RESOLVED by the binding ruling: shell-owned resume lock, not a
generation counter.** The earlier generation-counter design *detected* the
manual-toggle race then over-reacted (one tap silently aborted every remaining
restart) across an 18-call-site fan-out (two of them, MQTT's, invisible to a
`*Hosting` grep). The ruling (§2.4) replaces it with a shell-owned
`_resumeInProgress` surfaced as one `hostsBusy` bool and a single
`AbsorbPointer` around the Gateway card body — the race is *eliminated* (no
toggle possible mid-resume), the churn is ~10 lines in 2 files, and the test is
a deterministic widget assertion (L12), not a source-grep. `onManualHostToggle`,
`_resumeGeneration`, and guard G8 are deleted. **The one thing the reviewer must
still confirm:** the resume loop's `finally` (plus the 2 s-per-host / 5 s-overall
bounds) genuinely always clears `_resumeInProgress`, so a wedged bind can never
leave the Gateway permanently frozen — L12's wedged-host case exists for exactly
this.

**R3 — CI cannot verify the thing this spec is for; the Android on-device proof
is now MANDATORY.** Every functional change in §1 only manifests in a *release
build on a real device*: `INTERNET` matters only in the release manifest merge,
`NSLocalNetworkUsageDescription` only on physical iOS hardware, the macOS
entitlements only under a sandboxed signed build. The guard tests assert
*presence of text*, not *effect*. The one real end-to-end proof reachable on
this Windows dev machine — the **Wi-Fi-free `adb forward` + Python-probe Modbus
poll against a release APK** (§7, R3) — is folded into T6's completion criteria
**verbatim and non-optional**: without `INTERNET` the bind throws and the host
never reaches `running`, so the bind itself is the proof. iOS's Local Network
prompt stays unprovable here and remains a user-owned on-device checklist, never
a CI green.

Lesser risks worth a look: the §4.3 canvas-capture change (now scale-corrected,
M5) alters `InteractiveViewer`'s pan extent for small content across **every**
canvas editor (LD, FBD, SFC, HMI), not just the one that reported the bug — and
its live-zoom coverage is the fiddliest single piece of §4; the §1.4 Gradle
block runs on AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20, where
`signingConfigs { create("release") { … } }` inside a conditional plus the
`require(...)` guards (m12) is valid but less-travelled than the doc-standard
unconditional form; and the `0.9.0+2` bump is irreversible upward per store once
uploaded.

---

## §12 — Execution shape (for the plan)

Six tasks. **T1, T2, and T3 are now independent and run in parallel** (the R2
ruling dissolved T3's old dependency on T1 — there is no guard G8 to home in the
config file; T3's lifecycle tests live in their own files). T3 is the risky one.

| # | Task | Model · Effort | Depends on | Notes |
|---|---|---|---|---|
| T1 | **Platform config + signing scaffold + guard tests** — §1.1-§1.4, §1.5's version/manifest/index edits, `key.properties.example`, root `.gitignore`, `platform_config_guard_test.dart` **G1-G7** (G8 deleted) | sonnet · medium | — | Mechanical and exactly specified; the whole value is in getting the literal strings right, which the guard test then pins. Closes the headline blocker on its own. Parallel with T2/T3. |
| T2 | **UX polish** — §4.1-§4.4, the four DEFERRED rows, plus browser verification at all three viewports. **Lands as its OWN PR** (m16): it is an unrelated PR #18 follow-up, not part of store readiness, and should be reviewable/mergeable on its own | sonnet · medium | — | Independent of everything else; parallel with T1/T3. Four small, well-localised edits with existing tests to keep green. §4.3 (canvas M5) is the fiddliest. |
| T3 | **App lifecycle** — §2 in full: the `WidgetsBindingObserver`, the state machine (§2.1, incl. the M8 rejected-`hidden`-suspend rationale), the `_LifecycleHost` closure table (8 uniform + MQTT special), the awaited `flushPendingAutosaveNow()` (B2), suspend/resume, the shell-owned `_resumeInProgress` + `hostsBusy`/`AbsorbPointer` (R2 ruling), the resume banner incl. the MQTT line, `kLogSourceLifecycle`, `lifecycle_pause_test.dart` **L1-L12**, `refresh_rate_pref_test.dart` S1-S5 | **opus · high** | — (parallel) | The risky one. Touches the 3487-line shell's timer core and adds one `hostsBusy` param + one `AbsorbPointer` to the 5739-line Gateway (no per-helper edits). Twelve behavioural cases; R1/R2 both live here. Its own PR. |
| T4 | **CI workflow** — §3, `.github/workflows/ci.yml`: `vars.`-gated platform jobs (B3), debug-signed-vs-signed conditional artifact names (B4), no manual zip (M6), CocoaPods-retry iOS step (m13), verified by an actual run on the branch | sonnet · medium | T1 (Android job needs the signing block), T3 (gate must pass the new tests) | Iterative by nature — expect two or three pushes to get the runner matrix and the secret-detection step right. Verify `gate`, `ios`, `windows` go green with **no** secrets configured, and that the Android artifact is named `…-debugsigned` in that case. |
| T5 | **Docs** — §8: SHIPPING.md overhaul incl. the §8.2 asset checklist, new `docs/mobile-packaging.md` (incl. the full pause-setting per-platform copy, the M8 `detached` edge, the §5 registrant decision), PROJECT_BRIEF fix, bacnet/trends notes, DEFERRED rows (close 4, add the §10 rows incl. MQTT secure-storage), the §9 supersession banners | sonnet · medium | T1-T4 | Written after the code so it documents what actually shipped. |
| T6 | **Knowledge base + final verification** — §8.1's `CL-` entry + `canonical-manifest.json`; then the §7 matrix end to end: full suite, analyze, Android release build **both ways**, the **mandatory Wi-Fi-free `adb forward` + Python-probe Modbus proof (R3)**, Windows build, browser verification incl. the settings dialog at 390×844 + landscape. **Completion criteria carry the concrete numbers so T5 doesn't guess: the re-derived `flutter test` count and version `0.9.0+2`** (m17) | sonnet · medium | T1-T5 | The verification-before-completion gate. No "done" claim before the R3 on-device bind/poll is observed. |

T1 and T2 are independent and should be dispatched in parallel. T3 is a solo
run. T4 needs T1 and T3 landed. T5 and T6 are sequential closers.
