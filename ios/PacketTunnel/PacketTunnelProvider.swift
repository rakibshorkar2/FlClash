import Foundation
import NetworkExtension
import os.log

private let log = OSLog(subsystem: "com.follow.flClash.PacketTunnel", category: "PacketTunnelProvider")

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isTunnelRunning = false
    private let appGroupIdentifier = "group.com.follow.flClash"
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("[IOS-VPN] startTunnel requested", log: log, type: .info)
        
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let homeDirPath = containerURL?.path ?? NSHomeDirectory()
        
        setupBridgeCallbacks()
        
        let tunnelNetworkSettings = createNetworkSettings()
        setTunnelNetworkSettings(tunnelNetworkSettings) { [weak self] error in
            if let error = error {
                os_log("[IOS-VPN] setTunnelNetworkSettings failed: %{public}@", log: log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            
            guard let self = self else {
                completionHandler(TunnelError.managerUnavailable)
                return
            }
            
            self.isTunnelRunning = true
            self.startPacketPump()
            self.initializeGoCore(homeDir: homeDirPath, options: options)
            
            os_log("[IOS-VPN] Tunnel established successfully", log: log, type: .info)
            completionHandler(nil)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("[IOS-VPN] stopTunnel with reason: %{public}d", log: log, type: .info, reason.rawValue)
        isTunnelRunning = false
        stopTun()
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: messageData, options: []) as? [String: Any],
              let methodString = jsonObject["method"] as? String else {
            completionHandler?(nil)
            return
        }
        
        if methodString == "getTraffic" {
            let trafficChar = getTraffic(false)
            if let trafficChar = trafficChar {
                let trafficStr = String(cString: trafficChar)
                free(trafficChar)
                completionHandler?(trafficStr.data(using: .utf8))
            } else {
                completionHandler?(nil)
            }
            return
        }
        
        if methodString == "getTotalTraffic" {
            let trafficChar = getTotalTraffic(false)
            if let trafficChar = trafficChar {
                let trafficStr = String(cString: trafficChar)
                free(trafficChar)
                completionHandler?(trafficStr.data(using: .utf8))
            } else {
                completionHandler?(nil)
            }
            return
        }
        
        completionHandler?(nil)
    }
    
    private func createNetworkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 9000
        
        let ipv4Settings = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings
        
        let ipv6Settings = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [64])
        ipv6Settings.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6Settings
        
        let dnsSettings = NEDNSSettings(servers: ["172.19.0.2", "223.5.5.5"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        
        return settings
    }
    
    private func setupBridgeCallbacks() {
        flclash_ios_install_bridge()
        
        flclash_ios_set_write_packet_cb { [weak self] data, len, family in
            guard let self = self, self.isTunnelRunning, let data = data, len > 0 else { return }
            let packetData = Data(bytes: data, count: len)
            let protoNumber: NSNumber = (family == 30) ? (AF_INET6 as NSNumber) : (AF_INET as NSNumber)
            self.packetFlow.writePackets([packetData], withProtocols: [protoNumber])
        }
    }
    
    private func startPacketPump() {
        guard isTunnelRunning else { return }
        
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isTunnelRunning else { return }
            
            for (index, packet) in packets.enumerated() {
                let proto = protocols[index].int32Value
                let family: Int32 = (proto == AF_INET6) ? 30 : 2
                
                packet.withUnsafeBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        flclash_iosPacketFromSwift(UnsafeMutableRawPointer(mutating: baseAddress), Int32(rawBuffer.count), family)
                    }
                }
            }
            
            self.startPacketPump()
        }
    }
    
    private func initializeGoCore(homeDir: String, options: [String: NSObject]?) {
        let initParams: [String: Any] = [
            "home-dir": homeDir,
            "version": 1
        ]
        guard let initJsonData = try? JSONSerialization.data(withJSONObject: initParams, options: []),
              let initJsonStr = String(data: initJsonData, encoding: .utf8) else {
            return
        }
        
        let setupParams: [String: Any] = [
            "test-url": "http://www.gstatic.com/generate_204",
            "selected-map": [:]
        ]
        guard let setupJsonData = try? JSONSerialization.data(withJSONObject: setupParams, options: []),
              let setupJsonStr = String(data: setupJsonData, encoding: .utf8) else {
            return
        }
        
        initJsonStr.withCString { initCString in
            setupJsonStr.withCString { setupCString in
                quickSetup(nil, UnsafeMutablePointer(mutating: initCString), UnsafeMutablePointer(mutating: setupCString))
            }
        }
    }
}
