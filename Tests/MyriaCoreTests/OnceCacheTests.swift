import Foundation
import Testing
@testable import MyriaCore

/// A value that is itself nil is still a value: loaded once, kept.
@Test func onceCacheKeepsOptionals() {
    let cache = OnceCache()
    var loads = 0
    let a: Int? = cache.value("a") { loads += 1; return 7 }
    let b: Int? = cache.value("a") { loads += 1; return 8 }
    let c: Int? = cache.value("none") { loads += 1; return nil }
    let d: Int? = cache.value("none") { loads += 1; return 9 }
    #expect(a == 7 && b == 7 && c == nil && d == nil && loads == 2)
    #expect(cache.contains("none"))
}
