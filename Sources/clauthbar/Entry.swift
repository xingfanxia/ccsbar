import ClauthBarKit

/// The thin executable: all logic lives in the ClauthBarKit library (so a test
/// target can `@testable import` it). This is just the `@main` entry that hands
/// off to the library's `runClauthBar()`.
@main
struct ClauthBarMain {
    @MainActor
    static func main() { runClauthBar() }
}
