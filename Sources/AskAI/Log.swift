import Foundation
import OSLog

/// Unified-logging handle for the app.
///
/// `NSLog` from this bundle did not reliably surface in `log show`/`log stream`,
/// which would make Stage 2's "did the service actually reach my code?" check a
/// false negative. `Logger` with an explicit subsystem is queryable by
/// subsystem, which is stable. `.notice` and above are persisted by default, so
/// `log show` finds them without `--info`/`--debug`.
enum Log {
    static let subsystem = "com.yourname.AskAI"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let service = Logger(subsystem: subsystem, category: "service")
    static let panel = Logger(subsystem: subsystem, category: "panel")
    static let llm = Logger(subsystem: subsystem, category: "llm")
}
