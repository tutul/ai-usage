import Foundation
import UsageCore

public struct ClaudeProvider: UsageProvider {
    public let service = Service.claude
    let credentials: ClaudeCredentialSource
    let endpoint: URL

    public init(
        credentials: ClaudeCredentialSource = .init(),
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(try credentials.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(UserAgent.claude, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await HTTP.perform(request)
        return try ClaudeUsageParser.parse(body: body, observedAt: now)
    }
}

public struct CodexProvider: UsageProvider {
    public let service = Service.codex
    let credentials: CodexCredentialSource
    let endpoint: URL

    public init(
        credentials: CodexCredentialSource = .init(),
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    ) {
        self.credentials = credentials
        self.endpoint = endpoint
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(try credentials.accessToken())", forHTTPHeaderField: "Authorization")
        if let account = try credentials.accountID() {
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.setValue(UserAgent.codex, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await HTTP.perform(request)
        return try CodexUsageParser.parse(body: body, observedAt: now)
    }
}
