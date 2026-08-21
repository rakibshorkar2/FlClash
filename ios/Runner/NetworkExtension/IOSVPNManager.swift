import Foundation
import NetworkExtension

final class IOSVPNManager {
    static let shared = IOSVPNManager()
    
    private var manager: NETunnelProviderManager?
    private var statusObserver: Any?
    private var onStatusChange: ((TunnelStatus) -> Void)?
    
    private init() {
        setupObserver()
    }
    
    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupObserver() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let session = notification.object as? NETunnelProviderSession else { return }
            let status = TunnelStatus.from(neStatus: session.status)
            self.onStatusChange?(status)
        }
    }
    
    func setStatusListener(_ listener: @escaping (TunnelStatus) -> Void) {
        self.onStatusChange = listener
        if let currentStatus = currentStatus {
            listener(currentStatus)
        }
    }
    
    var currentStatus: TunnelStatus? {
        guard let manager = manager else { return nil }
        return TunnelStatus.from(neStatus: manager.connection.status)
    }
    
    func loadOrCreateManager(completion: @escaping (Result<NETunnelProviderManager, TunnelError>) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                completion(.failure(.saveConfigurationFailed(error.localizedDescription)))
                return
            }
            
            if let existingManager = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == TunnelConfiguration.tunnelBundleIdentifier
            }) {
                self?.manager = existingManager
                completion(.success(existingManager))
                return
            }
            
            let newManager = NETunnelProviderManager()
            let protocolConfiguration = NETunnelProviderProtocol()
            protocolConfiguration.providerBundleIdentifier = TunnelConfiguration.tunnelBundleIdentifier
            protocolConfiguration.serverAddress = "127.0.0.1"
            protocolConfiguration.providerConfiguration = [
                "groupContainer": TunnelConfiguration.appGroupIdentifier
            ]
            
            newManager.protocolConfiguration = protocolConfiguration
            newManager.localizedDescription = TunnelConfiguration.tunnelDescription
            newManager.isEnabled = true
            
            newManager.saveToPreferences { saveError in
                if let saveError = saveError {
                    completion(.failure(.saveConfigurationFailed(saveError.localizedDescription)))
                    return
                }
                newManager.loadFromPreferences { reloadError in
                    if let reloadError = reloadError {
                        completion(.failure(.saveConfigurationFailed(reloadError.localizedDescription)))
                        return
                    }
                    self?.manager = newManager
                    completion(.success(newManager))
                }
            }
        }
    }
    
    func startTunnel(options: [String: Any]? = nil, completion: @escaping (Result<Void, TunnelError>) -> Void) {
        loadOrCreateManager { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let manager):
                guard manager.isEnabled else {
                    manager.isEnabled = true
                    manager.saveToPreferences { saveError in
                        if let saveError = saveError {
                            completion(.failure(.saveConfigurationFailed(saveError.localizedDescription)))
                            return
                        }
                        do {
                            try (manager.connection as? NETunnelProviderSession)?.startTunnel(options: options as [String: NSObject]?)
                            completion(.success(()))
                        } catch {
                            completion(.failure(.startTunnelFailed(error.localizedDescription)))
                        }
                    }
                    return
                }
                do {
                    try (manager.connection as? NETunnelProviderSession)?.startTunnel(options: options as [String: NSObject]?)
                    completion(.success(()))
                } catch {
                    completion(.failure(.startTunnelFailed(error.localizedDescription)))
                }
            }
        }
    }
    
    func stopTunnel(completion: @escaping (Result<Void, TunnelError>) -> Void) {
        guard let manager = manager else {
            loadOrCreateManager { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let mgr):
                    (mgr.connection as? NETunnelProviderSession)?.stopTunnel()
                    completion(.success(()))
                }
            }
            return
        }
        (manager.connection as? NETunnelProviderSession)?.stopTunnel()
        completion(.success(()))
    }
    
    func sendProviderMessage(data: Data, completion: @escaping (Data?) -> Void) {
        guard let manager = manager,
              let session = manager.connection as? NETunnelProviderSession,
              session.status == .connected else {
            completion(nil)
            return
        }
        do {
            try session.sendProviderMessage(data) { responseData in
                completion(responseData)
            }
        } catch {
            completion(nil)
        }
    }
}
