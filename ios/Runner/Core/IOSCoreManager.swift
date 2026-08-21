import Foundation

final class IOSCoreManager {
    static let shared = IOSCoreManager()
    
    private init() {}
    
    func invokeMethod(payload: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(nil)
            return
        }
        
        IOSVPNManager.shared.sendProviderMessage(data: jsonData) { responseData in
            guard let data = responseData,
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(jsonObject)
        }
    }
}
