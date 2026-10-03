import Foundation

public enum UpkeepPrivilegedHelperConstants {
  public static let label = "com.chengzhong.Upkeep.PrivilegedHelper"
  public static let machServiceName = "com.chengzhong.Upkeep.PrivilegedHelper"
  public static let launchDaemonPlistName = "com.chengzhong.Upkeep.PrivilegedHelper.plist"
}

@objc(UpkeepPrivilegedHelperProtocol)
public protocol UpkeepPrivilegedHelperProtocol: NSObjectProtocol {
  func ping(withReply reply: @escaping () -> Void)

  func canTrashApplications(withReply reply: @escaping (Bool) -> Void)

  func trashApplications(
    paths: [String],
    withReply reply: @escaping (String?) -> Void
  )

  func installAppStorePackage(
    packagePath: String,
    receiptPath: String,
    applicationPath: String,
    withReply reply: @escaping (String?) -> Void
  )
}
