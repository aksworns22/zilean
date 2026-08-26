import Foundation

protocol CodexHarnessPreparing {
    func prepare(in directory: URL) throws
}

struct CodexHarnessPreparer: CodexHarnessPreparing {
    private let fileManager: FileManager
    private let promptTemplateLoader: any PromptTemplateLoading

    init(
        fileManager: FileManager = .default,
        promptTemplateLoader: any PromptTemplateLoading = BundlePromptTemplateLoader()
    ) {
        self.fileManager = fileManager
        self.promptTemplateLoader = promptTemplateLoader
    }

    func prepare(in directory: URL) throws {
        let instructionsURL = directory.appendingPathComponent("AGENTS.md", isDirectory: false)
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: instructionsURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CodexHarnessPreparationError.agentsPathIsDirectory
            }
            return
        }

        do {
            let data = Data(try promptTemplateLoader.load(.codexInstructions).utf8)
            try data.write(to: instructionsURL, options: .withoutOverwriting)
        } catch let error as PromptTemplateLoadingError {
            throw error
        } catch {
            throw CodexHarnessPreparationError.cannotCreateInstructions
        }
    }
}

enum CodexHarnessPreparationError: LocalizedError {
    case agentsPathIsDirectory
    case cannotCreateInstructions

    var errorDescription: String? {
        switch self {
        case .agentsPathIsDirectory:
            "선택한 폴더의 AGENTS.md 경로가 폴더입니다. 해당 폴더를 정리한 뒤 다시 시도해 주세요."
        case .cannotCreateInstructions:
            "선택한 폴더에 AGENTS.md를 만들 수 없습니다. 폴더의 쓰기 권한을 확인해 주세요."
        }
    }
}
