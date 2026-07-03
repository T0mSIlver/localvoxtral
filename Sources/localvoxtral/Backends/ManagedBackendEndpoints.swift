import Foundation

/// Fixed localhost endpoints for app-managed backends. Deliberately NOT
/// 8000/8080 so a user-run server never collides with the managed ones.
///
/// NOTE: a parallel PR introduces `BackendCatalog` with the same ports; the
/// wiring PR reconciles the duplication.
enum ManagedBackendEndpoints {
    static let voxmlxPort = 8471
    static let mlxLMPort = 8472
    static let realtimeURLString = "ws://127.0.0.1:8471/v1/realtime"
    static let polishingURLString = "http://127.0.0.1:8472/v1/chat/completions"
}
