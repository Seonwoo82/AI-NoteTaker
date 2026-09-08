import OSLog

enum NoteTakerLog {
    static let subsystem = "com.seonwoo.notetaker"
    static let smoke = Logger(subsystem: subsystem, category: "smoke-record")
}
