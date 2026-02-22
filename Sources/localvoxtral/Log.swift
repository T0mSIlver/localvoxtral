import os

/// Centralised loggers for the application. Each subsystem component gets its
/// own category so messages can be filtered in Console.app with:
///   `subsystem:com.localvoxtral  category:Microphone`
enum Log {
    private static let subsystem = "com.localvoxtral"

    static let microphone = Logger(subsystem: subsystem, category: "Microphone")
    static let dictation = Logger(subsystem: subsystem, category: "Dictation")
    static let realtime = Logger(subsystem: subsystem, category: "Realtime")
    static let mlxRealtime = Logger(subsystem: subsystem, category: "MlxRealtime")
    static let insertion = Logger(subsystem: subsystem, category: "Insertion")
}
