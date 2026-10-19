import Foundation

struct UpdateProgress: Hashable, Sendable {
  var fractionCompleted: Double?
  var status: String

  static func indeterminate(_ status: String) -> UpdateProgress {
    UpdateProgress(fractionCompleted: nil, status: status)
  }

  var percentText: String? {
    guard let fractionCompleted else { return nil }
    return "\(Int((min(max(fractionCompleted, 0), 1) * 100).rounded()))%"
  }

  static func clamp(_ value: Double) -> Double {
    let normalized = value > 1.0001 ? value / 100 : value
    return min(max(normalized, 0), 1)
  }
}
