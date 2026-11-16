import Foundation
extension Error {
    var message: String { (self as? LocalizedError)?.errorDescription ?? String(describing: self) }
}
