import Foundation

/// Fixed localhost endpoints for app-managed backends. Deliberately NOT
/// 8000/8080 so a user-run server never collides with the managed ones.
enum ManagedBackendEndpoints {
    static let speechdPort = BackendCatalog.speechd.port
    static let polishdPort = BackendCatalog.polishd.port
    static let realtimeURLString = "ws://127.0.0.1:\(speechdPort)/v1/realtime"
    static let polishingURLString = "http://127.0.0.1:\(polishdPort)/v1/chat/completions"
}
