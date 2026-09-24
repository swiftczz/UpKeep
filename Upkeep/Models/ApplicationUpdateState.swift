import Observation

@MainActor
@Observable
final class ApplicationUpdateState {
  private(set) var isUpdating = false
  private(set) var progress: UpdateProgress?

  func begin() {
    progress = .indeterminate("正在更新…")
    isUpdating = true
  }

  func report(_ progress: UpdateProgress) {
    guard isUpdating, self.progress != progress else { return }
    self.progress = progress
  }

  func finish() {
    isUpdating = false
    progress = nil
  }
}
