import Foundation

struct TunnelConfiguration {
    static let appGroupIdentifier = "group.com.follow.flClash"
    static let tunnelBundleIdentifier = "com.follow.flClash.PacketTunnel"
    static let tunnelDescription = "FlClash"
    
    static var groupContainerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
    
    static var groupContainerPath: String? {
        return groupContainerURL?.path
    }
}
