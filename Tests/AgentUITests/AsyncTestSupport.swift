import Foundation

@MainActor
enum ModelFixtures {
    static func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }
}
