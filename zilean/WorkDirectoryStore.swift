import Foundation

enum WorkDirectoryStoreError: LocalizedError, Equatable {
    case notDirectory
    case inaccessible

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            "저장된 작업 폴더를 찾을 수 없습니다. 폴더가 이동되거나 삭제되었을 수 있습니다."
        case .inaccessible:
            "저장된 작업 폴더에 쓸 수 없습니다. 접근 권한을 확인한 뒤 다른 폴더를 선택하세요."
        }
    }
}

nonisolated struct WorkDirectoryStore {
    static let directoryPathKey = "selectedWorkDirectoryPath"

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        key: String = WorkDirectoryStore.directoryPathKey
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.key = key
    }

    func savedDirectory() throws -> URL? {
        guard let path = userDefaults.string(forKey: key) else { return nil }
        return try validatedDirectory(URL(fileURLWithPath: path))
    }

    @discardableResult
    func save(_ directory: URL) throws -> URL {
        let directory = try validatedDirectory(directory)
        userDefaults.set(directory.path, forKey: key)
        return directory
    }

    func clear() {
        userDefaults.removeObject(forKey: key)
    }

    func validatedDirectory(_ directory: URL) throws -> URL {
        let directory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkDirectoryStoreError.notDirectory
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw WorkDirectoryStoreError.inaccessible
        }
        return directory
    }
}
