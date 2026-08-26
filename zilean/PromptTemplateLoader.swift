import Foundation

nonisolated enum ZileanPromptTemplate: String, CaseIterable {
    case codexInstructions = "codex-instructions"
    case mcpInstructions = "mcp-instructions"
    case retrospective = "retrospective"
    case retrospectiveFeedback = "retrospective-feedback"
    case feedback = "feedback"

    var displayName: String {
        switch self {
        case .codexInstructions:
            "Codex 기본 지침"
        case .mcpInstructions:
            "MCP 초기화 지침"
        case .retrospective:
            "집중 타이머 완료 회고"
        case .retrospectiveFeedback:
            "회고 피드백 재시도"
        case .feedback:
            "기간별 피드백"
        }
    }
}

nonisolated protocol PromptTemplateLoading {
    func load(_ template: ZileanPromptTemplate) throws -> String
    func render(_ template: ZileanPromptTemplate, values: [String: String]) throws -> String
}

nonisolated struct BundlePromptTemplateLoader: PromptTemplateLoading {
    private let bundle: Bundle

    init(bundle: Bundle? = nil) {
        self.bundle = bundle ?? Bundle(for: PromptTemplateBundleMarker.self)
    }

    func load(_ template: ZileanPromptTemplate) throws -> String {
        guard let url = bundle.url(
            forResource: template.rawValue,
            withExtension: "md"
        ) else {
            throw PromptTemplateLoadingError.fileNotFound(template)
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PromptTemplateLoadingError.fileIsEmpty(template)
            }
            return contents
        } catch let error as PromptTemplateLoadingError {
            throw error
        } catch {
            throw PromptTemplateLoadingError.cannotRead(template)
        }
    }

    func render(_ template: ZileanPromptTemplate, values: [String: String]) throws -> String {
        values.reduce(try load(template)) { prompt, value in
            prompt.replacingOccurrences(of: "{{\(value.key)}}", with: value.value)
        }
    }
}

nonisolated enum PromptTemplateLoadingError: LocalizedError, Equatable {
    case fileNotFound(ZileanPromptTemplate)
    case fileIsEmpty(ZileanPromptTemplate)
    case cannotRead(ZileanPromptTemplate)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(template):
            "\(template.displayName) 프롬프트 파일을 찾을 수 없습니다. 앱을 다시 설치하거나 지원팀에 문의해 주세요."
        case let .fileIsEmpty(template):
            "\(template.displayName) 프롬프트 파일이 비어 있습니다. 파일 내용을 확인해 주세요."
        case let .cannotRead(template):
            "\(template.displayName) 프롬프트 파일을 읽을 수 없습니다. 앱을 다시 설치하거나 파일 권한을 확인해 주세요."
        }
    }
}

private nonisolated final class PromptTemplateBundleMarker {}
