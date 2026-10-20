import Foundation
import UpkeepPrivilegedHelperProtocol

enum PrivilegedHelperConnection {
    static func withConnection<Value>(
        configure: (NSXPCConnection) -> Void = { _ in },
        perform operation: (NSXPCConnection) throws -> Value
    ) throws -> Value {
        guard let executable = Bundle.main.executableURL,
            let requirement = CodeSignature.designatedRequirement(
                at: executable.deletingLastPathComponent().appendingPathComponent(
                    "UpkeepPrivilegedHelper"))
        else {
            throw NSError(
                domain: "Upkeep.PrivilegedHelper", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法验证助手的签名，请重新安装完整的 Upkeep 应用。"])
        }
        let connection = NSXPCConnection(
            machServiceName: UpkeepPrivilegedHelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: UpkeepPrivilegedHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        configure(connection)
        connection.resume()
        defer { connection.invalidate() }
        return try operation(connection)
    }
}
