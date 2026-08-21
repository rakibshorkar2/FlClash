import Foundation
import NetworkExtension

enum TunnelStatus: String {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
    
    static func from(neStatus: NEVPNStatus) -> TunnelStatus {
        switch neStatus {
        case .invalid:
            return .invalid
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .reasserting:
            return .reasserting
        case .disconnecting:
            return .disconnecting
        @unknown default:
            return .invalid
        }
    }
}

enum TunnelError: Error, CustomStringConvertible {
    case managerUnavailable
    case permissionDenied
    case saveConfigurationFailed(String)
    case startTunnelFailed(String)
    case extensionCrash(String)
    case invalidConfiguration
    
    var description: String {
        switch self {
        case .managerUnavailable:
            return "VPN manager is unavailable"
        case .permissionDenied:
            return "VPN permission was denied by user or system policy"
        case .saveConfigurationFailed(let reason):
            return "Failed to save VPN configuration: \(reason)"
        case .startTunnelFailed(let reason):
            return "Failed to start tunnel: \(reason)"
        case .extensionCrash(let reason):
            return "Packet tunnel extension failed: \(reason)"
        case .invalidConfiguration:
            return "Tunnel configuration is missing or invalid"
        }
    }
}
