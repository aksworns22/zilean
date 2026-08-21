import Foundation

nonisolated struct ZileanMCPConfiguration {
    static let serverName = "zilean"

    let executableURL: URL?
    let rootDirectory: URL
    private let fileManager: FileManager

    init(
        executableURL: URL? = Bundle.main.executableURL,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Zilean", isDirectory: true)
                .appendingPathComponent("MCP", isDirectory: true)
    }

    func prepareCodexArguments() throws -> [String] {
        guard let executableURL else {
            throw ZileanMCPConfigurationError.executableNotFound
        }

        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw ZileanMCPConfigurationError.cannotCreateDirectory(rootDirectory)
        }

        let serverArguments = [
            ZileanMCPServer.commandLineFlag,
            "--configuration-directory",
            rootDirectory.path,
        ]
        let encodedArguments = serverArguments.map(tomlString).joined(separator: ", ")

        return [
            "app-server",
            "--stdio",
            "-c", "mcp_servers.\(Self.serverName).command=\(tomlString(executableURL.path))",
            "-c", "mcp_servers.\(Self.serverName).args=[\(encodedArguments)]",
            "-c", "mcp_servers.\(Self.serverName).required=true",
            "-c", "mcp_servers.\(Self.serverName).enabled=true",
            "-c", "mcp_servers.\(Self.serverName).default_tools_approval_mode=\"auto\"",
            "-c", "mcp_servers.\(Self.serverName).env.LLVM_PROFILE_FILE=\"/dev/null\"",
        ]
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

nonisolated enum ZileanMCPConfigurationError: LocalizedError, Equatable {
    case executableNotFound
    case cannotCreateDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Zilean MCP 서버 실행 파일을 찾을 수 없습니다. 앱을 다시 설치한 뒤 시도해 주세요."
        case let .cannotCreateDirectory(directory):
            "Zilean MCP 설정 폴더를 만들 수 없습니다: \(directory.path)"
        }
    }
}
