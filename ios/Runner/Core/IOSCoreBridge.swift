import Foundation
import Flutter

final class IOSCoreBridge {
    private let channel: FlutterMethodChannel
    
    init(messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(name: "fl_clash/core_ios", binaryMessenger: messenger)
        self.channel.setMethodCallHandler(handle)
        setupStatusObservation()
    }
    
    private func setupStatusObservation() {
        IOSVPNManager.shared.setStatusListener { [weak self] status in
            guard let self = self else { return }
            self.channel.invokeMethod("vpnStatus", arguments: status.rawValue)
        }
        
        IOSCoreCallbacks.shared.addEventListener { [weak self] eventData in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.channel.invokeMethod("event", arguments: eventData)
            }
        }
    }
    
    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getGroupContainerPath":
            result(TunnelConfiguration.groupContainerPath)
            
        case "start":
            let options = call.arguments as? [String: Any]
            IOSVPNManager.shared.startTunnel(options: options) { startResult in
                DispatchQueue.main.async {
                    switch startResult {
                    case .success:
                        result(true)
                    case .failure(let error):
                        result(FlutterError(code: "START_FAILED", message: error.description, details: nil))
                    }
                }
            }
            
        case "stop":
            IOSVPNManager.shared.stopTunnel { stopResult in
                DispatchQueue.main.async {
                    switch stopResult {
                    case .success:
                        result(true)
                    case .failure(let error):
                        result(FlutterError(code: "STOP_FAILED", message: error.description, details: nil))
                    }
                }
            }
            
        case "invokeMethod":
            guard let arguments = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid method call arguments", details: nil))
                return
            }
            IOSCoreManager.shared.invokeMethod(payload: arguments) { response in
                DispatchQueue.main.async {
                    result(response)
                }
            }
            
        case "getStatus":
            let status = IOSVPNManager.shared.currentStatus?.rawValue ?? TunnelStatus.disconnected.rawValue
            result(status)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
