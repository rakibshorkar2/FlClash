import Foundation

typealias CoreEventCallback = ([String: Any]) -> Void

final class IOSCoreCallbacks {
    static let shared = IOSCoreCallbacks()
    
    private var eventListeners: [CoreEventCallback] = []
    private let lock = NSLock()
    
    private init() {}
    
    func addEventListener(_ listener: @escaping CoreEventCallback) {
        lock.lock()
        defer { lock.unlock() }
        eventListeners.append(listener)
    }
    
    func dispatchEvent(_ eventData: [String: Any]) {
        lock.lock()
        let listeners = eventListeners
        lock.unlock()
        
        for listener in listeners {
            listener(eventData)
        }
    }
}
