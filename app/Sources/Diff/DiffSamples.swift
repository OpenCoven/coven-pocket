import Foundation

/// Sample diffs for previews and tests.
enum DiffSamples {
    /// A realistic multi-file diff: a modified Swift file with two hunks, a
    /// created file, and a deleted file.
    static let multiFile = """
    diff --git a/Sources/App/Session.swift b/Sources/App/Session.swift
    index 1111111..2222222 100644
    --- a/Sources/App/Session.swift
    +++ b/Sources/App/Session.swift
    @@ -1,6 +1,7 @@ struct Session
     import Foundation

     struct Session {
    -    let id: String
    +    let id: UUID
    +    let title: String
         let createdAt: Date
     }
    @@ -14,3 +15,3 @@ extension Session {
         func summary() -> String {
    -        "session \\(id)"
    +        "\\(title) — \\(id.uuidString)"
         }
    diff --git a/Sources/App/SessionStore.swift b/Sources/App/SessionStore.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/Sources/App/SessionStore.swift
    @@ -0,0 +1,5 @@
    +import Foundation
    +
    +final class SessionStore {
    +    private(set) var sessions: [Session] = []
    +}
    diff --git a/Sources/App/Legacy.swift b/Sources/App/Legacy.swift
    deleted file mode 100644
    index 4444444..0000000
    --- a/Sources/App/Legacy.swift
    +++ /dev/null
    @@ -1,3 +0,0 @@
    -import Foundation
    -
    -typealias LegacySession = [String: String]
    """
}
