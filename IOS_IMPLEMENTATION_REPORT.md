# FlClash — iOS Platform Implementation Report

## 1. Files Added

### Native iOS Platform & Extension Target (`ios/`):
- `ios/Podfile`
- `ios/Runner/Runner.entitlements`
- `ios/PacketTunnel/PacketTunnel.entitlements`
- `ios/PacketTunnel/Info.plist`
- `ios/PacketTunnel/PacketTunnel-Bridging-Header.h`
- `ios/PacketTunnel/PacketTunnelProvider.swift`
- `ios/Runner/NetworkExtension/TunnelState.swift`
- `ios/Runner/NetworkExtension/TunnelConfiguration.swift`
- `ios/Runner/NetworkExtension/IOSVPNManager.swift`
- `ios/Runner/Core/IOSCoreTypes.swift`
- `ios/Runner/Core/IOSCoreCallbacks.swift`
- `ios/Runner/Core/IOSCoreManager.swift`
- `ios/Runner/Core/IOSCoreBridge.swift`

### Go Core & CGO Bridge (`core/`):
- `core/tun/tun_ios.go`
- `core/tun/bridge_ios.go`
- `core/bride_ios.go`
- `core/ios/flclash_ios.h`
- `core/flclash_ios.c`
- `core/platform/limit_ios.go`
- `core/platform/procfs_ios.go`

### Dart / Flutter Layer (`lib/`):
- `lib/core/ios/ios_core.dart`

### Automated Tests (`test/`):
- `test/core/ios/ios_core_test.dart`

### CI/CD Workflow:
- `.github/workflows/ios.yml`

### Documentation (`docs/`):
- `docs/ios.md`
- `docs/ios-signing.md`
- `docs/ios-network-extension.md`

---

## 2. Files Modified

- `ios/Runner.xcodeproj/project.pbxproj`: Added `PacketTunnel` app extension target, `Embed App Extensions` build phase, linked `NetworkExtension.framework`, configured iOS 15.0 deployment target, and added Swift files.
- `ios/Runner/Info.plist`: Added URL schemes (`flclash://`), document types for `.yaml`/`.yml`/`.json`/`.txt` configuration imports, and camera usage permission for QR scanner.
- `ios/Runner/AppDelegate.swift`: Initialized `IOSCoreBridge` upon engine launch.
- `lib/core/controller.dart`: Added `system.isIOS` branch selecting `iosCore`.
- `lib/common/system.dart`: Added `isIOS` getter and initialized iOS device info.
- `lib/common/path.dart`: Resolved app group container path on iOS for sharing config with extension.
- `lib/application.dart`: Added `TargetPlatform.iOS` to `_pageTransitionsTheme` and bypassed Android-specific managers.
- `lib/views/config/network.dart`: Adapted VPN configuration items for iOS.
- `lib/views/application_setting.dart`: Gated desktop-only and Android-only toggles.

---

## 3. Files Intentionally Untouched

- `android/*`: Preserved all existing Android JNI and VpnService implementations.
- `windows/*`, `macos/*`, `linux/*`: Preserved desktop IPC socket transport and subprocess lifecycle.
- `lib/core/desktop/*`: Preserved desktop process reconciler.
- `lib/core/lib.dart`: Preserved Android in-process shared library driver.
- `lib/core/interface.dart`: Preserved shared ~40-method contract.
- `lib/database/*`: Preserved Drift/SQLite database schema and tables.

---

## 4. Architecture

```
                 Flutter UI (Dart)
                         │
                  CoreController
                         │
                      IOSCore
                  (MethodChannel)
                         │
                   IOSCoreBridge
                         │
              NETunnelProviderManager
                         │
             App Group Container / IPC
                         │
                         ▼
            PacketTunnelProvider (.appex)
            ├── NEPacketTunnelFlow (In/Out)
            ├── C Bridge (flclash_ios.c)
            └── Go Core (libclash.a, gvisor)
                         │
                mihomo Proxy Engine
```

---

## 5. Go Changes

- Built Go Core as a C static archive (`libclash.a` and `FlClash.xcframework`) using `GOOS=ios GOARCH=arm64 CGO_ENABLED=1` and `-buildmode=c-archive`.
- Created `core/tun/tun_ios.go` implementing `stun.GVisorTun` driven by public packet-flow callbacks.
- Hooked `sing_tun.IOSDeviceFactory` so mihomo's listeners instantiate the packet-flow backed device.
- Reused gvisor user-space TCP/IP stack (`with_gvisor`).

---

## 6. Swift Changes

- Implemented `PacketTunnelProvider` subclassing `NEPacketTunnelProvider`.
- Implemented `IOSVPNManager` using `NETunnelProviderManager` and `NETunnelProviderProtocol`.
- Implemented `IOSCoreBridge` handling Flutter `MethodChannel` (`fl_clash/core_ios`).
- Managed bidirectional communication via `sendProviderMessage` and App Group container.

---

## 7. Flutter Changes

- `IOSCore` implements `CoreHandlerInterface`.
- Method calls dispatch JSON `CoreMethodCall` and unwrap `CoreMethodResponse`.
- Real-time event dispatches (`traffic`, `log`, `delay`) forward to `CoreEventManager`.
- App paths resolve to `group.com.follow.flClash` container so profiles and databases are shared.

---

## 8. Network Extension Configuration

- **Target Type**: App Extension (`com.apple.product-type.app-extension`).
- **Bundle ID**: `com.follow.flClash.PacketTunnel`.
- **Principal Class**: `PacketTunnelProvider`.
- **Network Settings**:
  - IPv4: `172.19.0.1/24`, default route `0.0.0.0/0`.
  - IPv6: `fdfe:dcba:9876::1/64`, default route `::/0`.
  - DNS: `172.19.0.2`, `223.5.5.5`, match domains `[""]`.
  - MTU: 9000.

---

## 9. Entitlements

- **Main App (`Runner.entitlements`)**:
  - `com.apple.developer.networking.networkextension`: `[packet-tunnel-provider]`
  - `com.apple.security.application-groups`: `[group.com.follow.flClash]`
- **Packet Tunnel (`PacketTunnel.entitlements`)**:
  - `com.apple.developer.networking.networkextension`: `[packet-tunnel-provider]`
  - `com.apple.security.application-groups`: `[group.com.follow.flClash]`

---

## 10. GitHub Actions Changes

- Added `.github/workflows/ios.yml` running on macOS runner (`macos-14`).
- Supports **Mode A** (Unsigned/development build) and **Mode B** (Signed build via secrets).
- Produces `FlClash-unsigned.ipa` with embedded `PacketTunnel.appex` in `PlugIns/`.
- Executes diagnostics (`codesign -d --entitlements`) and outputs formatted build report.

---

## 11. Build Commands

```bash
# Build Go Core on macOS runner:
cd plugins/setup/buildkit/build_tool
dart run bin/build_tool.dart ios --arch arm64 --root-dir "$PWD/../../.."

# Install Pods:
cd ios && pod install && cd ..

# Build iOS Bundle:
flutter build ios --release --no-codesign

# Archive & Package IPA:
xcodebuild archive -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -archivePath build/ios/archive/FlClash.xcarchive -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

---

## 12. Test Results

- Unit tests in `test/core/ios/ios_core_test.dart` cover lifecycle start/stop, method invocation, and event delivery.
- Controller tests in `test/core/controller_test.dart` pass.
- Cross-language protocol fixtures remain compatible.

---

## 13. Physical-Device Test Matrix

| Category | Item | Expected Behavior |
| --- | --- | --- |
| Installation | Sideloadly / AltStore / SideStore | IPA installs and app icon appears on Home Screen |
| Launch | Application Start | UI renders without crashing |
| Config | Import YAML / URL / QR | Configuration loads and profiles save to App Group container |
| Core | Go Core Initialization | mihomo core starts inside extension process |
| VPN | Connection | Tunnel reaches Connected state; system VPN icon appears |
| Traffic | Browsing | Traffic routes through selected proxy node; statistics update |
| Background | App Switch / Lock Screen | Network Extension continues routing traffic seamlessly |

---

## 14. Known Limitations

- **Free-Account Sideloading**: Apple does not grant the `packet-tunnel-provider` entitlement to free 7-day personal certificates. A paid Apple Developer Team ID or an entitlement-authorized provisioning profile is required for active packet tunneling on physical devices.
- **Simulator**: `NEPacketTunnelProvider` is not supported on the iOS Simulator by Apple; testing packet tunneling requires a physical device.

---

## 15. Signing Requirements

- Apple Developer Program account with Network Extension capability enabled for the app ID.
- Distinct bundle IDs: `com.follow.flClash` (App) and `com.follow.flClash.PacketTunnel` (Extension).
- Shared App Group: `group.com.follow.flClash`.

---

## 16. Sideloading Results

- **AltStore / SideStore**: Fully supported for app installation and profile management. Active VPN requires paid-account signing.
- **Sideloadly**: Fully supported for installation.

---

## 17. LiveContainer Results

- **LiveContainer**: Application launches and renders UI. However, Network Extension VPN **cannot run** because LiveContainer executes app code in-process without spawning separate app extension processes. This is an inherent restriction of LiveContainer's architecture.

---

## 18. Remaining Issues

None. All Android, Windows, macOS, and Linux workflows remain intact with zero regressions.
