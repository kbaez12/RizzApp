import Foundation

/// AnalysisServicing backed by POST /analyze. The base64 image exists only
/// inside the transient `AnalysisRequest`; never persisted or logged.
final class LiveAnalysisService: AnalysisServicing {
    private let client: APIClient
    private let onUsageUpdate: (UsageStatus) -> Void

    init(client: APIClient, onUsageUpdate: @escaping (UsageStatus) -> Void = { _ in }) {
        self.client = client
        self.onUsageUpdate = onUsageUpdate
    }

    func analyze(_ input: ConversationInput, requestID: UUID) async throws -> ChatAnalysis {
        let request = try AnalysisRequest(input: input, requestID: requestID)
        do {
            let result: AnalysisResult = try await client.send(try .analyze(request))
            onUsageUpdate(result.usage)
            return result.analysis
        } catch APIError.quotaExceeded(let usage) {
            if let usage {
                onUsageUpdate(usage)
            }
            throw APIError.quotaExceeded(usage)
        }
    }
}
