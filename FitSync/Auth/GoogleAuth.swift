import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct OAuthConfig: Sendable {
    let clientID: String
    let redirectScheme: String
    var redirectURI: String { "\(redirectScheme):/oauthredirect" }

    /// Read-only scopes. FitSync never writes to Google.
    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
    ]

    static func fromInfoPlist() -> OAuthConfig {
        let info = Bundle.main.infoDictionary ?? [:]
        return OAuthConfig(
            clientID: info["GoogleClientID"] as? String ?? "",
            redirectScheme: info["GoogleRedirectScheme"] as? String ?? ""
        )
    }
}

enum AuthError: LocalizedError {
    case notConfigured, cancelled, couldNotStart, noCode, notSignedIn
    case tokenEndpoint(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set GOOGLE_CLIENT_ID and GOOGLE_REDIRECT_SCHEME in Config.xcconfig."
        case .cancelled: return "Sign-in was cancelled."
        case .couldNotStart: return "Could not open the Google sign-in page."
        case .noCode: return "Google did not return an authorization code."
        case .notSignedIn: return "Sign in with Google first."
        case let .tokenEndpoint(status, body): return "Google token error \(status): \(body)"
        }
    }
}

/// Google OAuth 2.0 for an installed app: authorization code + PKCE, no client secret.
/// Tokens live in the Keychain; the access token is refreshed automatically.
actor GoogleAuth {
    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private let config: OAuthConfig
    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?

    init(config: OAuthConfig) {
        self.config = config
        self.tokens = Keychain.load(Tokens.self)
    }

    static var hasStoredTokens: Bool { Keychain.load(Tokens.self) != nil }

    // MARK: Sign in

    func signIn() async throws {
        guard !config.clientID.hasPrefix("REPLACE_ME"), !config.clientID.isEmpty else { throw AuthError.notConfigured }

        let verifier = PKCE.makeVerifier()
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: OAuthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Do NOT add include_granted_scopes=true: legacy fitness.* scopes merged into
            // the token cause 403s on the Google Health API.
        ]

        let callback = try await OAuthBrowser.authorize(url: comps.url!, callbackScheme: config.redirectScheme)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.noCode }

        let response = try await tokenRequest([
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ])
        guard let refresh = response.refresh_token else { throw AuthError.tokenEndpoint(200, "No refresh token returned") }
        store(Tokens(accessToken: response.access_token,
                     refreshToken: refresh,
                     expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in))))
    }

    func signOut() {
        tokens = nil
        Keychain.delete()
    }

    // MARK: Access token

    /// Returns a token valid for at least 60 more seconds, refreshing if needed.
    /// Concurrent callers share one refresh request.
    func validAccessToken() async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }

        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { () throws -> Tokens in
            let r = try await self.tokenRequest([
                "client_id": self.config.clientID,
                "refresh_token": current.refreshToken,
                "grant_type": "refresh_token",
            ])
            return Tokens(accessToken: r.access_token,
                          refreshToken: r.refresh_token ?? current.refreshToken,
                          expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in)))
        }
        refreshTask = task
        defer { refreshTask = nil }
        let fresh = try await task.value
        store(fresh)
        return fresh.accessToken
    }

    // MARK: Helpers

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 400 || status == 401 {
                // invalid_grant = refresh token revoked or expired (e.g. OAuth app left in "Testing").
                signOut()
            }
            throw AuthError.tokenEndpoint(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ t: Tokens) {
        tokens = t
        Keychain.save(t)
    }
}

// MARK: - PKCE

enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - System browser sign-in (Google forbids embedded web views)

@MainActor
enum OAuthBrowser {
    private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    // Keeps the session and its presenter alive while the sheet is open.
    private static var active: (ASWebAuthenticationSession, Presenter)?

    static func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let presenter = Presenter()
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                Task { @MainActor in active = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cancelled)
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            active = (session, presenter)
            if !session.start() {
                active = nil
                continuation.resume(throwing: AuthError.couldNotStart)
            }
        }
    }
}
