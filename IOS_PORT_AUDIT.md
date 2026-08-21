# iOS Port Audit (Phase 1)

Status: **Draft for review** · Scope: analysis only, no production code changes.

This document audits the FlClash repository to determine exactly what is required to add
first-class iOS support, and how to do it without regressing Android, Windows, macOS, or Linux.
It is the Phase 1 deliverable of the iOS port.

---

## 1. Executive summary

FlClash is a Flutter (Dart) front end over a Go core (Clash.Meta / mihomo). Today the core is
integrated two different ways:

- **Android**: the Go core is compiled with cgo as an in-process shared library (`libclash.so`)
  loaded via JNI, driven over a MethodChannel. TUN uses an Android file descriptor.
- **Desktop** (Windows/macOS/Linux): the Go core is compiled without cgo as a standalone
  executable (`FlClashCore`) launched as a subprocess, driven over an IPC socket, with lifecycle
  ownership managed by `lib/core/desktop/`.

There is **no `ios/` directory**, no iOS Go target, no iOS workflow, and no iOS-specific
handling anywhere in the Dart layer. The repository's own conventions (`System.isAndroid`,
`CoreController`, `setup.dart`, the setup build tool, the podscript-based Go build) all stop at
the four existing platforms.

The recommended iOS architecture is a **third, dedicated integration path**: the Go core is
compiled with cgo as a **static archive** (`libclash.a`) wrapped in an **XCFramework**, embedded
in a native **Network Extension (Packet Tunnel Provider)** target. The packet tunnel does not
create a `utun` device (impossible inside the NE sandbox without private APIs) and does not use
Android-style file descriptors. Instead, the FlClash Go core implements a custom `tun.Tun` /
`GVisorTun` device that is fed by and written to the NE packet flow through the fully public
`NEPacketTunnelProvider.packetFlow.readPackets(...)` / `writePackets(...)` APIs. All of mihomo's
existing listener logic (handlers, DNS hijack, rules, gvisor stack wiring) is reused unchanged by
adding one tiny device-factory hook to the Clash.Meta fork.

Key findings:

1. The Flutter layer is structured to keep a single shared `CoreHandlerInterface`, so an iOS
   bridge can plug in without touching the ~40 core methods.
2. The Android TUN/cgo path is genuinely Android-only (`//go:build android && cgo`); it must be
   split, not reused, for iOS.
3. The C callback bridge (`bride.c`) is portable as-is; only the Android-specific Go file that
   wires it must gain an iOS counterpart.
4. The gvisor stack (already the default build tag, `with_gvisor`) is the only viable iOS stack,
   and sing-tun's `GVisorTun` interface is exactly the seam at which a packet-flow-backed device
   plugs in.
5. The most widely used approach in production apps (WireGuard, sing-box-for-apple, ProxyCat,
   PIA) reaches for a private key-value-coding file descriptor on `packetFlow`. That violates the
   project rule *"Do not use private Apple APIs"*, so this port uses the public
   `readPackets`/`writePackets` bridge instead.
6. CI is the only build environment (no MacBook). GitHub Actions `macos-14` runners are
   sufficient for both unsigned sideload IPAs and signed TestFlight builds.

---

## 2. Current platform architecture

### 2.1 Flutter app layout (relevant parts)

| Area | File | Notes |
| --- | --- | --- |
| Platform detection | `lib/common/system.dart` | `System.isAndroid/isDesktop/isWindows/isMacOS/isLinux`; **no `isIOS`**; initialised from `DeviceInfoPlugin`. |
| Core selection | `lib/core/controller.dart` | `CoreController` picks `CoreLib` if `system.isAndroid`, else `CoreService`. **No iOS branch.** |
| Shared core API | `lib/core/interface.dart` | `CoreHandlerInterface` — the ~40-method contract both implementations implement. Keep unchanged. |
| Android core impl | `lib/core/lib.dart` + `lib/plugins/service.dart` | In-process MethodChannel core (`$packageName/service`). |
| Desktop core impl | `lib/core/service.dart` | Composition root: `IPCCoreTransport` + `DesktopCoreLifecycle` + `CoreRpcClient` + Windows `HelperLauncher`. |
| RPC protocol | `lib/core/method.dart`, `lib/core/event.dart` | `CoreMethod` enum (~38 methods), `CoreMethodCall`/`CoreMethodResponse`, `CoreEventManager`/`CoreEventListener`. |
| Paths | `lib/common/path.dart` | Uses `path_provider` (Application Support / Cache / Temp); desktop `corePath` = bundled `FlClashCore` executable — **invalid on iOS**. |
| Entry point | `lib/main.dart` | `RustLib.init()` only when `system.isDesktop`; `HttpOverrides.global = FlClashHttpOverrides()`. |
| App shell | `lib/application.dart` | `PageTransitionsTheme` only registered for android/windows/linux/macOS. |
| Build targets | `setup.dart` | Only `android/linux/macos/windows`; host must be linux/macos/windows. |

### 2.2 Core bridge layering

```
Flutter UI / providers
        │  CoreHandlerInterface (lib/core/interface.dart)
        ├── CoreLib  (Android)  ── MethodChannel("$packageName/service") ──> native plugin
        │        native plugin (android core) ── JNI ──> libclash.so (Go, cgo)
        └── CoreService (desktop) ── IPC transport ──> FlClashCore.exe (Go, no cgo)
                          └── lifecycle: lib/core/desktop/lifecycle.dart
```

### 2.3 Go core (`core/`)

| File | Build constraint | Role |
| --- | --- | --- |
| `lib.go` | `cgo` | cgo exports; `TunHandler` (start/close/handleProtect/handleResolveProcess); dial hooking. |
| `server.go` | `!cgo` | Desktop IPC framing (4-byte LE length prefix, 64MB cap, batched events). |
| `method.go` | — | `MethodCall`/`MethodResponse` JSON protocol. |
| `message.go` | — | Event batching (16 ms, batch 32, queue 256, non-blocking). |
| `tun/tun.go` | `android && cgo` | Starts TUN via `LC.Tun{FileDescriptor, MTU:9000, AutoRoute:false, AutoDetectInterface:false, Stack: gvisor|system}`. |
| `bride.go` | `android && cgo` | Go side of the C callback bridge (`protect`/`resolve_process`/`result`/`release_object`). |
| `bride.c` / `bride.h` | none (portable C) | Global function pointers + wrappers; set by the platform layer. |
| `platform/procfs.go` | `linux` | Process resolution via procfs. |
| `platform/limit.go` | `android && cgo` | FD limit raising. |
| `go.mod` | — | module `core`; `replace github.com/metacubex/mihomo => ./Clash.Meta`; pins `sing-tun v0.4.21`, `metacubex/gvisor` (gvisor fork), mihomo fork commit `80362fc` (FlClash branch). |

`core/Clash.Meta` is a git submodule (`git@github.com:chen08209/Clash.Meta.git`, branch `FlClash`).
It is empty in the local checkout and fetched by CI (`submodules: recursive`).

### 2.4 Desktop (macOS/Windows/Linux) integration

- `plugins/setup` is the Go build harness. `buildkit/build_tool` (Dart) drives `go build` per
  target: Android produces a c-shared lib; desktop produces executables. Options default to
  `tags: with_gvisor`, `go_ldflags: -w -s`, `libName: libclash`, `outputDir: libclash`.
- On macOS the core binary is embedded in the app bundle: `macos/Runner.xcodeproj/project.pbxproj`
  has a `FlClashCore` file reference (`../libclash/macos/FlClashCore`) with a `Copy Core` build
  phase and `CodeSignOnCopy`.
- `plugins/setup/macos/setup.podspec` has a `script_phase` that runs `build_pod.sh`, which
  forwards to `buildkit/build_tool build macos` with an arch map (arm64→arm64, x86_64→amd64).
- `plugins/setup/ios/setup.podspec` exists but is a **dummy** (platform ios 11.0, empty class, no
  script phase). This is the natural seam for the iOS Go build.
- `plugins/rust_api` (flutter_rust_bridge 2.12.0, `interprocess` IPC crate) already ships an iOS
  pod + Cargokit, but is only *used* at runtime by the desktop transport.

### 2.5 Android integration

- `android/core/src/main/cpp/core.cpp` — JNI bridge: `startTun`, `stopTun`, `forceGC`,
  `updateDNS`, `invokeMethod`, `setEventListener`, `getTraffic`, etc.
- `android/core/src/main/java/com/follow/clash/core/Core.kt` — JNI declarations.
- `System.loadLibrary("core")`; TUN works through `VpnService` which hands the Go core a real
  file descriptor (`fd`). `protect(fd)` keeps the proxy's own sockets out of the tunnel.
- `bride.c` globals are assigned by JNI (`JNI_OnLoad`) so Go can call back into Java.

---

## 3. Android-only dependency inventory

These are the concrete places where the code base assumes Android (or non-iOS) and would break or
misbehave on iOS:

| # | Where | What assumes Android/desktop | iOS impact |
| --- | --- | --- | --- |
| A1 | `lib/core/controller.dart` | `Platform.isAndroid` gate | On iOS neither `CoreLib` nor `CoreService` is selected; no core is started. |
| A2 | `lib/common/system.dart` | No `isIOS` | iOS UI falls into `isDesktop=false`/`isAndroid=false` grey zone; `isDesktop` returns `true` on iOS? **verify** — see Risks R1. |
| A3 | `lib/common/path.dart` | `Platform.resolvedExecutable` dir for the desktop core binary | Not applicable on iOS; must use container-relative Application Support/Caches. |
| A4 | `core/tun/tun.go` | `//go:build android && cgo` | No TUN implementation exists for iOS. |
| A5 | `core/bride.go` | `//go:build android && cgo` | No iOS wiring of `result`/`release_object`/`free_string` callbacks. |
| A6 | `core/platform/limit.go` | `//go:build android && cgo` | `setrlimit` style FD bump is Android-specific. |
| A7 | `core/platform/procfs.go` | `//go:build linux` | No process-resolution source for iOS (not needed; NE exempts extension sockets). |
| A8 | `core/lib.go` | `cgo`; `handleProtect`/`handleResolveProcess` | Must become no-ops on iOS; sockets in the NE extension are exempt from the tunnel, and there is no `resolve_process` equivalent. |
| A9 | `plugins/wifi_ssid` | No `ios/` directory | `MethodChannel` calls throw `MissingPluginException` unless guarded. |
| A10 | `lib/main.dart`, `lib/application.dart` | `RustLib.init()` desktop-gated; platform-gated UI themes | iOS needs its own (largely no-op) branches. |
| A11 | `setup.dart` + `plugins/setup` build tool | Only android/desktop targets | No iOS build target. |
| A12 | `.github/workflows/build.yaml` | Ubuntu, tag-triggered | No iOS artifact, no signing. |
| A13 | `plugins/proxy`, `plugins/window_ext`, `plugins/wifi_ssid` | Desktop/Android-only plugins | Must be excluded or guarded on iOS. |

---

## 4. iOS blockers (high level)

1. **No iOS Flutter shell** — there is no `ios/` directory, so `flutter build ios` cannot run.
2. **No iOS Go target** — the build tooling cannot produce a Go archive for iOS; cgo/c-archive
   flags are unknown to it.
3. **No iOS core driver** — `CoreController` has no iOS branch and the NE extension has no way to
   own the core.
4. **TUN is impossible via the existing code paths** — Android `fd` and desktop `utun` both fail
   inside the NE sandbox.
5. **C callback wiring** — `result`/`release_object`/`free_string` are only wired for Android.
6. **Wifi-SSID / on-demand dependency** — `wifi_ssid` has no iOS implementation and is used by the
   UI (connectivity manager, on-demand page, permission flow).
7. **Signing/entitlements** — not present; Network Extension needs the
   `com.apple.developer.networking.networkextension` entitlement with a `packet-tunnel-provider`
   dictionary, and separate bundle IDs for the app and the extension.
8. **CI** — the only build machine type is GitHub Actions; iOS needs a macOS runner and Apple
   signing secrets.

---

## 5. Go / CGO analysis and fixes

### 5.1 Build tags

Current relevant tags:

- `lib.go`: `cgo` (all cgo platforms, incl. iOS when we build with cgo).
- `server.go`: `!cgo` (desktop only).
- `tun/tun.go`: `android && cgo`.
- `bride.go`: `android && cgo`.
- `platform/limit.go`: `android && cgo`; `platform/procfs.go`: `linux`.

iOS will be built with `CGO_ENABLED=1` and `GOOS=ios`, so `cgo`-tagged files compile on iOS. The
`android`-gated files must be split:

| Existing file | Change |
| --- | --- |
| `tun/tun.go` | becomes `tun/tun_android.go` (`android && cgo`), or keep as-is and add `tun/tun_ios.go` (`ios && cgo`). |
| `bride.go` | add `bride_ios.go` (`ios && cgo`) assigning the same `bride.c` globals from an iOS C shim. |
| `platform/limit.go` | add no-op `limit_ios.go` (`ios && cgo`). |
| `platform/procfs.go` | add no-op `procfs_ios.go` (`ios`). |

`bride.c`/`bride.h` have **no** build constraints and are portable C; they compile unchanged on iOS.

### 5.2 TUN device — the core of the port

**Why the existing paths fail on iOS.** On iOS, `NEPacketTunnelProvider` runs in a sandboxed
extension process. It cannot create a `utun` device via the Darwin `AF_SYSTEM`/`com.apple.net.utun_control`
ioctl path (sing-tun's `tun_darwin.go`), and no file descriptor is handed to us by the system. The
two viable strategies are:

- **(A) Private KVC fd** — `packetFlow.value(forKeyPath: "socket.fileDescriptor")` to obtain a raw
  fd and reuse `sing-tun`'s `FdTun` unmodified. Used by WireGuard, sing-box-for-apple, ProxyCat,
  PIA. **Rejected** here because it relies on a private key path on `NEProviderPacketFlow` (the
  project hard rule forbids private Apple APIs).
- **(B) Public packet-flow bridge (chosen)** — implement a custom `tun.Tun`/`GVisorTun` in Go that
  is backed by C function pointers; Swift feeds it from `packetFlow.readPackets` and drains
  `packetFlow.writePackets`. Fully public API.

**Verified sing-tun facts (v0.4.21, the version pinned by the core):**

- `type Tun interface { io.ReadWriter; Close() error }`.
- `type GVisorTun interface { Tun; WritePacket(pkt *stack.PacketBuffer) (int, error); NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) }`.
- `NewStack("gvisor", opts)` (via `NewGVisor`) requires `opts.Tun` to implement `GVisorTun`, then
  `Start()` calls `t.tun.NewEndpoint()`, wraps it in a `LinkEndpointFilter` (broadcast/multicast
  bounce), attaches TCP/UDP/ICMP forwarders, and registers a route table. All of this is reused
  unchanged on iOS.
- The Darwin wire format is `[4-byte protocol prefix][IP packet]` with prefix
  `{0x00,0x00,0x00,AF_INET=2}` or `{0x00,0x00,0x00,AF_INET6=30}`. `NEPacket` carries its
  `protocolFamily` separately, so the Go bridge must encode the family when writing to Swift and
  read it from `NEPacket` when receiving.

**Chosen device design (`core/tun/tun_ios.go`):**

```
Swift: packetFlow.readPackets(...) ──> C callback: flclash_ios_packet_from_swift(bytes,len,family)
        └─> Go: non-blocking push {data, family} onto inject queue
              └─> goroutine: endpoint.InjectInbound(protoFor(family), packetBuffer)   [inbound to stack]

Go stack -> channel.Endpoint.WritePackets -> notify handler -> t.WritePacket(pkt)
        pkt.AsSlices() + family = pkt.NetworkProtocolNumber
        └─> C callback: flclash_ios_write_to_swift(bytes,len,family)  [Swift -> packetFlow.writePackets]
```

- `NewEndpoint()` returns `channel.New(size, mtu, "")` (verified present in `metacubex/gvisor`
  `pkg/tcpip/link/channel`), with a `WriteNotify` handler that drains the queue and forwards each
  packet to Swift; NIC options mirror the FdTun path (`QDisc: fifo.New(ep, 1, 1000)`).
  Alternative: a minimal hand-rolled `stack.LinkEndpoint` whose `WritePackets` calls the Swift
  callback directly (used by several NE apps) — fewer moving parts, more code to test.
- `Read(p)` pops the inject queue (raw IP packet, no 4-byte prefix). `Write(p)`/`Name()/Start()`/
  `Close()`/`UpdateRouteOptions()` are implemented as required by the interface (Write forwards to
  Swift for the non-gvisor path; Start/UpdateRouteOptions are no-ops on iOS; Close signals
  termination and closes the packet flow).
- `handleProtect` → no-op (NE exempts the extension's own sockets). `handleResolveProcess` → "".
- `MTU`/`address`/`dns` come from the existing `tun.Start(fd, stack, address, dns)` signature;
  on iOS the `fd` argument is ignored and the packet-flow device is created instead.

### 5.3 C callback bridge (bride) on iOS

`bride.c` defines global function pointers that the native layer assigns:

```c
void (*release_object_func)(void *obj);
void (*free_string_func)(char *data);
void (*protect_func)(void *tun_interface, int fd);
char* (*resolve_process_func)(void *tun_interface, int protocol, const char *source, const char *target, int uid);
void (*result_func)(void *invoke_Interface, const char *data);
```

- **Android**: `JNI_OnLoad` assigns them to JNI-calling thunks.
- **iOS**: add `bride_ios.go` (`//go:build ios && cgo`) that exports setters
  (`flclash_ios_set_callbacks(...)`) which Swift calls once at core startup. `result` must marshal
  JSON `MethodCall` payloads back to Flutter through the app (the extension forwards results to the
  app process via the app group container or the NE-provider `message` API; see §10). The tun
  device's Swift-write callback is a separate function pointer set the same way.

### 5.4 mihomo fork hook (Clash.Meta submodule)

`listener/sing_tun/server.go` line 466 calls `tunNew(tunOptions)`; on non-Windows that is
`tun.New(options)` (`server_notwindows.go`), which would try to create a real utun inside the NE
sandbox and fail. Two small fork changes on the `FlClash` branch:

```go
// server_notwindows.go: change constraint to
//go:build !windows && !ios

// NEW server_ios.go
//go:build ios
package sing_tun

import tun "github.com/metacubex/sing-tun"

var IOSDeviceFactory func(options tun.Options) (tun.Tun, error)

func tunNew(options tun.Options) (tun.Tun, error) {
    if IOSDeviceFactory != nil {
        return IOSDeviceFactory(options)
    }
    return tun.New(options)
}
```

The FlClash core then sets `sing_tun.IOSDeviceFactory` to construct the packet-flow device before
`tun.Start` calls `sing_tun.New(...)`. **Result: mihomo's entire listener stack (handler, DNS
hijack, rule matching, gvisor wiring, auto-route off) runs untouched on iOS.**

### 5.5 Go toolchain and XCFramework build

- Build with `GOOS=ios GOARCH=arm64 CGO_ENABLED=1` and `-buildmode=c-archive`, `CC=clang` with the
  iphoneos SDK sysroot (`-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)`), keeping
  the existing `tags=with_gvisor` and `-w -s` ldflags. Output: `libclash.a` + `libclash.h`.
- Wrap the device slice as `libclash/ios/libclash.xcframework` (fat/universal not required; a
  single `ios-arm64` slice suffices). A simulator slice (`ios-arm64-simulator`) is optional for
  UI-only simulator builds; the NE extension itself is never run in the simulator.
- `plugins/setup` additions: a new target `ios` (device) in `buildkit` (`target.dart`,
  `go_builder.dart` for the clang/CC and SDK discovery, `options.dart` for the iOS output dir),
  and an iOS `script_phase` in `plugins/setup/ios/setup.podspec` mirroring the macOS podscript.
- `setup.dart` gains an `ios` target; host OS check must allow macOS only for iOS.

---

## 6. Rust blockers

- `plugins/rust_api` (flutter_rust_bridge 2.12.0, `interprocess` crate) already has an iOS pod +
  Cargokit scaffolding; the Rust crate is pure-std and compiles for iOS.
- At **runtime** Rust is only initialised for desktop (`lib/main.dart`: `if (system.isDesktop)
  RustLib.init()`), and the desktop transport is the only consumer. On iOS the core runs inside the
  NE extension and talks to Flutter via MethodChannel, so Rust is **not required at runtime**.
- Action: keep the iOS pod for completeness, but do not initialise Rust on iOS; guard the desktop
  transport path so it is never selected on iOS.

---

## 7. Flutter plugin blockers

| Plugin | iOS status | Action |
| --- | --- | --- |
| `wifi_ssid` | no `ios/` | Guard all call sites (`lib/manager/connectivity_manager.dart`, `lib/views/config/on_demand.dart`, `lib/common/permission.dart`); feature-detect or return unavailable on iOS. |
| `proxy`, `window_ext` | desktop-only | Already desktop-gated; verify no import leaks into iOS build. |
| `window_manager`, `tray_manager`, `launch_at_startup`, `hotkey_manager`, `screen_retriever`, `defer_pointer` | desktop-only | Used only under desktop branches today; confirm. |
| `mobile_scanner`, `file_picker`, `image_picker`, `app_links`, `package_info_plus`, `device_info_plus`, `connectivity_plus`, `path_provider`, `shared_preferences`, `url_launcher` | iOS OK | Supported out of the box. |
| `flutter_js` | iOS OK | Used for scripting; confirm no private APIs. |
| `rust_api` | iOS pod exists | Compile; do not init at runtime on iOS. |

---

## 8. Network Extension requirements

1. **Targets**: two Xcode targets — the app (`Runner`, bundle id `com.yourcompany.flclash`) and the
   packet tunnel (`FlClashPacketTunnel`, bundle id `com.yourcompany.flclash.packet-tunnel`,
   `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`).
2. **Entitlements**:
   - App: `com.apple.developer.networking.networkextension` with
     `{"com.apple.developer.networking.networkextension": ["packet-tunnel-provider"]}` and app
     groups (for config sharing).
   - Extension: the same networkextension entitlement + app group matching the app.
3. **App Groups**: a shared container (e.g. `group.com.yourcompany.flclash`) so the app can write
   config/geo data the extension reads; the core's Application Support lives in the extension's own
   container but config exchange must go through the group container.
4. **VPN behaviour**: the extension calls `NETunnelProviderProtocol`/`NEPacketTunnelNetworkSettings`
   (`IPv4Settings` with the TUN addresses, `MTU`, `DNSSettings`, and `includedRoutes = default`)
   so the system routes all traffic into `packetFlow`. This is separate from and layered on the
   Go-side routing; the Go core sees the packet flow, not the system routes.
5. **Deployment target**: raise to **iOS 15+** for modern `readPacketObjects`/`writePacketObjects`
   (the existing iOS podspec says 11.0; bump it).
6. **Memory**: the NE extension runs under a tight jetsam budget (~15–50 MB RSS on real devices).
   Mitigations: keep `with_gvisor` (user-space stack, no root access needed), reuse buffers,
   disable debug logging, avoid loading geo databases into RAM more than once, and test under
   Instruments on-device.
7. **Lifecycle**: the extension is (re)started by the system; the app must observe `NEVPNStatus`
   and drive start/stop via `NETunnelProviderManager`. This maps to the project's existing
   "latest-intent-safe" lifecycle discipline, but inside the extension the Go core is started
   directly (not via a desktop-style subprocess).

---

## 9. Signing & provisioning requirements

- A paid Apple Developer account (Team ID) is required for the Network Extension entitlement.
- **Unsigned/dev (sideload) mode**: build with `-m iphoneos` and ad-hoc or free-profile signing;
   install via Xcode/simulator/device tooling. NE entitlement in this mode is limited — on-device
   verification of actual packet tunnelling requires a paid account. The audit's stance: the CI
   unsigned IPA proves compile + embed + entitlements structure; real VPN validation needs the
   signed build.
- **Signed mode** via GitHub Actions: secrets `APPLE_CERTIFICATE` (base64 `.p12`),
   `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_BUNDLE_ID`, `APPLE_PROFILE_APP`,
   `APPLE_PROFILE_NETWORK_EXTENSION`, and optionally `APPSTORE_CONNECT_API_KEY*` for
   `xcrun altool`/notary. `codesign`/`codesign --deep` the app and the embedded `.appex`;
   validate with `codesign -d --entitlements :- <app>`.
- The two bundle IDs must be distinct and the extension must be embedded under
   `Runner.app/PlugIns/FlClashPacketTunnel.appex`.

---

## 10. Recommended iOS architecture (target design)

```
                        ┌───────────────────────────────┐
                        │ Runner.app (Flutter, iOS)     │
                        │  FlClash UI / providers       │
                        │  CoreController ─ iOS branch  │
                        │  IOSCore (MethodChannel)      │
                        │  connectivity/on-demand UI    │
                        └──────┬────────────────────────┘
                               │ NEVPNStatusManager /
                               │ NETunnelProviderManager
                               │ (app group container shares config)
                        ┌──────▼────────────────────────┐
                        │ FlClashPacketTunnel.appex     │
                        │  NEPacketTunnelProvider       │
                        │   packetFlow.readPackets      │
                        │   packetFlow.writePackets     │
                        │   └── C shim (flclash_ios.c)  │
                        │        ├─ bridge callbacks    │
                        │        └─ packet device hooks │
                        │   Go core (libclash.a)        │
                        │    mihomo listeners (via      │
                        │    IOSDeviceFactory hook)     │
                        │    gvisor stack + custom      │
                        │    packet-flow GVisorTun      │
                        │    result() -> app bridge     │
                        └───────────────────────────────┘
```

Layering rules (respect existing invariants):

- **No packet routing through Flutter.** All packet traffic stays in the extension.
- **No Android JNI/VpnService/fd reuse.** iOS uses its own packet-flow device.
- **`CoreHandlerInterface` is the contract** — the iOS bridge implements it in Flutter, and the Go
  side keeps the same `method.go`/`message.go` protocol, so all ~40 core methods and events work
  unchanged.
- **Config flow**: Flutter writes config/geo into the app-group container; the extension's Go core
  reads it. Core start/stop is driven by `NEVPNStatus` (the extension owns the core lifecycle once
  running, mirroring `ServiceState`'s ownership rule for Android services).
- **Events/logs/traffic**: `result()`/event batches are forwarded from the extension to the app via
  the NE-provider messaging API (a tiny side channel) or by the app reading a status file in the
  group container; MethodChannel delivers them to the Flutter providers. Simpler alternative:
  the app polls traffic counters via the group container, but event push is preferred for parity
  with `CoreEventManager`.

---

## 11. GitHub Actions build plan

New workflow `.github/workflows/ios.yml`, `workflow_dispatch` (+ optional `push` tags), on
`macos-14`:

1. Checkout with `submodules: recursive`.
2. Install Flutter (version pinned like `build.yaml`, 3.44.4), run `flutter pub get`.
3. `flutter analyze` + `flutter test` (CI parity).
4. `dart run setup.dart ios` (or `buildkit/build_tool build ios`) → produces
   `libclash/ios/libclash.xcframework`.
5. `flutter build ios --release --no-codesign` (or signed via the `-P/--dart-define`/secrets).
6. Embed + sign the extension; verify structure:
   - `test -d build/ios/iphoneos/Runner.app/PlugIns/FlClashPacketTunnel.appex`
   - `codesign -d --entitlements :- build/ios/iphoneos/Runner.app` and the `.appex` → assert the
     networkextension entitlement and app group.
7. Package `Runner.ipa` (`xcodebuild -archivePath ... -exportArchive` or `xcrun`).
8. Final report: print binary paths, sizes, entitlements dump, and the embedded `.appex` path.

Two modes via inputs/secrets:

- `signed=false` (default): unsigned/ad-hoc IPA — proves build + embed.
- `signed=true`: decrypt `APPLE_CERTIFICATE`, install profiles, sign both targets, export IPA.

Keep `.github/workflows/build.yaml` untouched for existing platforms.

---

## 12. Verification & acceptance

- **Unit/tests**: extend `test/core/controller_test.dart` and `test/core/protocol_contract_test.dart`
  for the iOS branch; keep `test/fixtures/core_protocol.json` green on all platforms.
- **CI**: green `flutter analyze --no-fatal-infos` + `flutter test --reporter expanded`, iOS IPA
  produced, entitlements validated.
- **On-device (real iPhone 15 Pro, signed build)**: connect via a working subscription, start VPN,
  confirm `NEVPNStatus` connected, traffic counters move, pages load through the tunnel, geo/rule
  updates apply, and the tunnel survives app backgrounding. Simulator/IPA-install alone is **not**
  proof of NE support.

---

## 13. Risks and open questions

| # | Risk / question | Impact | Mitigation |
| --- | --- | --- | --- |
| R1 | `System.isDesktop` / `Platform.isIOS` semantics — `isIOS` must be added to `system.dart`; confirm no code path misclassifies iOS as desktop. | Core selection, paths, UI themes | Add `isIOS`; add explicit iOS branches where `isDesktop` is consulted (main.dart, application.dart, controller.dart). |
| R2 | gvisor `channel` endpoint + notify loop is unproven at FlClash's packet rates; WireGuard-style direct-endpoint may be needed. | Performance/correctness | Prototype both; measure on device; keep the device abstraction so the swap is local to `tun_ios.go`. |
| R3 | Exact `NEPacket` semantics (multiple packets per read, `protocolFamily` per packet) must match the Go bridge. | Packet corruption | Unit-test the C shim byte mapping; log first packets on device during bring-up. |
| R4 | NE memory budget is tight; gvisor + full mihomo + geo DBs in one process. | Jetsam kills | Trim RSS (avoid duplicate geo loads, tune gvisor buffer sizes already set to 20KB), disable verbose logging, test under Memory Graph. |
| R5 | The private-API KVC fd approach is the de-facto standard; our public-API bridge is more novel. | Robustness | Keep the design as public-API-first; document the KVC fallback in code comments only if a maintainer later opts in (requires rule change). |
| R6 | mihomo fork (`Clash.Meta` FlClash branch) must accept the 2-file `tunNew` hook; submodule pins a commit. | Repo governance | Submit the change upstream to `chen08209/Clash.Meta`; pin the new commit in `core/go.mod` (replace + commit). |
| R7 | `flutter build ios` requires the pod plugins to resolve (Cargokit, etc.) on CI without a local pod install step. | Build failure | Use `pod install` in the workflow; pin CocoaPods version. |
| R8 | `wifi_ssid`/`connectivity_plus` iOS availability differences change on-demand ("connect only on Wi-Fi") behaviour. | Feature regression | Feature-detect; disable SSID-based on-demand on iOS or use the group container/`NEVPNProtocol` rules instead. |
| R9 | App group + NE messaging channel design is a new mechanism. | Event delivery parity | Prototype the side channel early; fall back to shared-file polling for traffic/status if messaging proves flaky. |
| R10 | No local Mac available — all iteration happens on CI; device validation requires a paid team + TestFlight. | Slow feedback | Make CI produce installable IPAs every run; use `xcrun devicectl`/`altool` where possible; plan a final on-device validation pass. |
| R11 | Deployment target 11.0 vs iOS 15+ APIs. | Compile errors | Bump deployment target to 15.0 in the iOS podspec and Xcode project; document it as a required OS floor. |
| R12 | `PageTransitionsTheme`/UI theming gated to four platforms may produce default (possibly Cupertino-less) styling on iOS. | Cosmetic | Add iOS to the theme map; optionally adopt Cupertino widgets in Phase 4. |

---

## 14. Invariants — what must NOT change

- The Go core remains mihomo/Clash.Meta; no reimplementation of routing rules or listeners.
- `CoreHandlerInterface` and the `method.go`/`message.go` protocol are shared across Android,
  desktop, and iOS.
- No packets are routed through Flutter; no `VpnService`/JNI/`/dev/net/tun` reuse on iOS.
- No private Apple APIs; no fake entitlements (VPN must genuinely work only when the real
  entitlement is present).
- Android and desktop build paths and workflows keep working (`build.yaml` untouched).
- Lifecycle ownership stays with the native layer: the extension owns the core while running;
  Flutter requests transitions but never becomes a second source of truth.
- Tests in `test/` and the `core_protocol.json` fixture remain green.

---

## 15. Implementation plan outline (phases 2–5)

1. **Phase 2 — Go iOS build (off-device)**:
   - Add `tun_ios.go`, `bride_ios.go`, `limit_ios.go`, `procfs_ios.go`.
   - Add `ios` target to `plugins/setup` buildkit + `setup.dart`; wire
     `plugins/setup/ios/setup.podspec` script phase.
   - Add the `tunNew` hook to the Clash.Meta fork; pin the new submodule commit.
   - Build `libclash.a`/XCFramework on CI (macOS runner) and run `go vet`/`go build` for
     `GOOS=ios`.
2. **Phase 3 — iOS Flutter shell + core driver**:
   - `flutter create --platforms=ios .` to generate `ios/`; add `PacketTunnel` target,
     entitlements, app group, plist keys, deployment target 15.0.
   - Add `System.isIOS`; `CoreController` iOS branch; `IOSCore` implementing
     `CoreHandlerInterface` over a MethodChannel; path handling via group container.
   - Guard `wifi_ssid`/desktop plugin call sites on iOS; keep `RustLib` desktop-only.
3. **Phase 4 — NE extension + packet-flow bridge**:
   - Implement `NEPacketTunnelProvider` (`startTunnel`/`stopTunnel`, network settings,
     `readPackets`/`writePackets` loops), the C shim wiring `bride.c` globals + device hooks.
   - Connect the Go `IOSDeviceFactory` to the packet-flow device; wire `result()` → app bridge.
   - UI: iOS-themed nav/transitions; VPN status + on-demand surfaces; reconnect-on-foreground.
4. **Phase 5 — CI + validation**:
   - `.github/workflows/ios.yml` (unsigned + signed modes, entitlements validation, final report).
   - On-device validation on iPhone 15 Pro (paid team), TestFlight, memory/perf profiling.

---

## 16. File-by-file change list (summary)

**New files**
- `core/tun/tun_ios.go` (`ios && cgo`) — packet-flow `GVisorTun` + `IOSDeviceFactory` wiring.
- `core/bride_ios.go` (`ios && cgo`) — exported setters for `bride.c` globals.
- `core/ios/flclash_ios.h` / `flclash_ios.c` — C shim (bridge callback setters, packet hooks).
- `core/platform/limit_ios.go`, `core/platform/procfs_ios.go` — no-ops.
- `ios/` (Flutter shell: Runner, PacketTunnel target, Info.plist, entitlements, Podfile).
- `.github/workflows/ios.yml`.
- `lib/core/ios_core.dart` — iOS `CoreHandlerInterface` implementation.
- (Clash.Meta fork) `listener/sing_tun/server_ios.go`.

**Modified files**
- `core/tun/tun.go` — narrow to `android && cgo` (or split into `tun_android.go`).
- `core/lib.go` — iOS-safe `handleProtect`/`handleResolveProcess` guards.
- `lib/common/system.dart` — add `isIOS` (and `isMobile`), init from `DeviceInfoPlugin`.
- `lib/core/controller.dart` — iOS branch.
- `lib/common/path.dart` — iOS-safe path resolution (Application Support in extension container,
  config via app group).
- `lib/main.dart` / `lib/application.dart` — iOS branches (Rust stays desktop-only; themes add iOS).
- `lib/manager/connectivity_manager.dart`, `lib/views/config/on_demand.dart`,
  `lib/common/permission.dart` — guard `wifi_ssid` on iOS.
- `plugins/setup/buildkit/...` (`target.dart`, `go_builder.dart`, `options.dart`) — iOS target;
  `build_pod.sh` iOS branch; `plugins/setup/ios/setup.podspec` script phase.
- `setup.dart` — `ios` target.
- `plugins/setup/ios/setup.podspec` — deployment target 11.0 → 15.0.
- `test/core/controller_test.dart` + protocol fixtures — iOS branch coverage.
- (Clash.Meta fork) `listener/sing_tun/server_notwindows.go` — exclude iOS from `tunNew` default.

---

## 17. Open decision record

| Decision | Recommendation | Reasoning |
| --- | --- | --- |
| TUN device | Public `readPackets`/`writePackets` Go bridge | Only public-API option; satisfies no-private-API rule; KVC fd is the fallback if perf proves inadequate. |
| Stack | gvisor (`with_gvisor`, already default) | System stack needs a real utun; unavailable in NE. |
| Bridge wiring | Reuse `bride.c` globals via iOS shim | Same call pattern as Android; minimal Go churn. |
| Core process | In-extension (same process as NE) | No subprocess allowed in NE; c-archive link, not exec. |
| mihomo integration | Fork hook on `tunNew` | Reuses 100% of mihomo listener logic. |
| Runtime Rust | None | Desktop IPC only; not needed in extension. |