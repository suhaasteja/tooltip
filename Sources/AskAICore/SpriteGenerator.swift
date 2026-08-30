import Foundation

/// One generated image, as returned by the API.
public struct GeneratedImage: Equatable, Sendable {
    public let data: Data
    /// As reported by the service. **Not assumed to be PNG**: format follows the
    /// model — `gemini-2.5-flash-image` returns PNG, `gemini-3-pro-image-preview`
    /// returns JPEG. The extractor decodes either, but anything that writes the
    /// bytes straight to disk must not guess the extension.
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Anything that can turn a prompt into an image.
///
/// Deliberately narrow, like `LLMClient`: the app only needs one image at a
/// time, and a small surface keeps a fake trivial to write.
public protocol SpriteGeneratorClient: Sendable {
    /// Generates an image.
    ///
    /// - Parameters:
    ///   - reference: an earlier image to keep the character consistent with.
    ///     This is how identity is held across sheets: generating each sheet
    ///     from the text prompt alone produces a visibly different character
    ///     every time.
    ///   - aspectRatio: **per request, not per client.** The requested grid and
    ///     the aspect ratio have to agree — asking for a 2x2 grid at 4:3 gets a
    ///     3x2 sheet back, which then slices wrong. See NOTES.md.
    func generate(
        prompt: String, reference: GeneratedImage?, aspectRatio: String?
    ) async throws -> GeneratedImage
}

public extension SpriteGeneratorClient {
    func generate(prompt: String) async throws -> GeneratedImage {
        try await generate(prompt: prompt, reference: nil, aspectRatio: nil)
    }
    func generate(prompt: String, reference: GeneratedImage) async throws -> GeneratedImage {
        try await generate(prompt: prompt, reference: reference, aspectRatio: nil)
    }
}

/// Everything that can go wrong, mapped to something a user can act on.
///
/// Separate from `LLMError` on purpose: the remedies differ. "You have no image
/// model configured" is not the same problem as "your chat model is wrong", even
/// when both are the same key.
public enum SpriteGeneratorError: Error, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case server(Int)
    /// The response was 200 but carried no image — usually a safety refusal,
    /// which arrives as a text part instead.
    case noImageReturned(String?)
    case decoding
    case network(String)
    case cancelled
    case badRequest(String)

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "No image API key set. Add one in Settings."
        case .unauthorized:
            return "The image API key was rejected. Check it in Settings."
        case .rateLimited:
            return "Rate limited by the image service. Try again in a moment."
        case .server(let code):
            return "The image service is having trouble (HTTP \(code)). Try again."
        case .noImageReturned(let text):
            // The model explains its refusal in a text part; showing that is far
            // more useful than "no image returned".
            if let text, !text.isEmpty {
                return "The model returned no image: \(text)"
            }
            return "The model returned no image. Try rewording the description."
        case .decoding:
            return "Couldn't read the image response."
        case .network(let detail):
            return "Network problem: \(detail)"
        case .cancelled:
            return "Cancelled."
        case .badRequest(let detail):
            return detail.isEmpty ? "The request was rejected." : detail
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network, .decoding: return true
        case .missingAPIKey, .unauthorized, .cancelled, .badRequest, .noImageReturned:
            return false
        }
    }
}

/// Settings for image generation.
public struct SpriteGeneratorConfiguration: Equatable, Sendable {

    /// Chosen for animation quality: it produces a genuinely varied walk cycle,
    /// where `gemini-2.5-flash-image`'s frames came back nearly identical.
    ///
    /// A **preview** endpoint — preview models get renamed and retired, so this
    /// must stay configurable. Changing it also changes the response's mime type,
    /// because format follows the model.
    public static let defaultModel = "gemini-3-pro-image-preview"

    public static let defaultBaseURL = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models")!

    /// Model directory, without the model name or `:generateContent`.
    public var baseURL: URL
    public var model: String
    /// `"1:1"`, `"4:3"`, … Sheet layouts want different shapes.
    public var aspectRatio: String
    public var imageSize: String

    public init(
        baseURL: URL = SpriteGeneratorConfiguration.defaultBaseURL,
        model: String = SpriteGeneratorConfiguration.defaultModel,
        aspectRatio: String = "4:3",
        imageSize: String = "1K"
    ) {
        self.baseURL = baseURL
        self.model = model
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
    }
}

/// Google's image models over plain REST.
///
/// No SDK and, unlike the reference implementation this replaces, no fal.ai in
/// the middle and no job queue: `generateContent` returns the image bytes inline
/// from a single POST. See NOTES.md.
public final class GeminiImageClient: SpriteGeneratorClient, @unchecked Sendable {

    private let apiKey: String?
    private let configuration: SpriteGeneratorConfiguration
    private let session: URLSession

    public init(
        apiKey: String?,
        configuration: SpriteGeneratorConfiguration = .init(),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.session = session
    }

    public func generate(
        prompt: String, reference: GeneratedImage?, aspectRatio: String?
    ) async throws -> GeneratedImage {
        try await send(prompt: prompt, reference: reference, aspectRatio: aspectRatio)
    }

    // MARK: - Request

    public func makeRequest(
        prompt: String, reference: GeneratedImage?, aspectRatio: String? = nil
    ) throws -> URLRequest {
        guard let apiKey, !apiKey.isEmpty else { throw SpriteGeneratorError.missingAPIKey }

        let url = configuration.baseURL
            .appendingPathComponent("\(configuration.model):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Google's own header. Not `Authorization: Bearer`, which is what the
        // OpenAI-compatible endpoint on the same host wants — the two clients
        // talk to the same domain with different auth.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var parts: [[String: Any]] = [["text": prompt]]
        if let reference {
            // Image first, then instruction: the reference is context for the
            // edit, and the ordering matches how the endpoint's examples read.
            parts.insert([
                "inline_data": [
                    "mime_type": reference.mimeType,
                    "data": reference.data.base64EncodedString(),
                ]
            ], at: 0)
        }

        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "imageConfig": [
                    "aspectRatio": aspectRatio ?? configuration.aspectRatio,
                    "imageSize": configuration.imageSize,
                ]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(
        prompt: String, reference: GeneratedImage?, aspectRatio: String?
    ) async throws -> GeneratedImage {
        let request = try makeRequest(
            prompt: prompt, reference: reference, aspectRatio: aspectRatio)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw SpriteGeneratorError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SpriteGeneratorError.cancelled
        } catch {
            throw SpriteGeneratorError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpriteGeneratorError.decoding
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapFailure(status: http.statusCode, body: data)
        }
        return try Self.image(fromResponse: data)
    }

    // MARK: - Response

    /// Pulls the first inline image out of a `generateContent` response.
    ///
    /// A pure static function so the wire format is unit-tested without a
    /// network, the same way `AnthropicClient.textDelta(fromSSELine:)` is.
    public static func image(fromResponse data: Data) throws -> GeneratedImage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SpriteGeneratorError.decoding }

        let candidates = root["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"]
            as? [[String: Any]]
        guard let parts else { throw SpriteGeneratorError.decoding }

        for part in parts {
            // Both spellings appear in Google's docs and SDKs.
            let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any]
            guard let inline,
                  let base64 = inline["data"] as? String,
                  let bytes = Data(base64Encoded: base64)
            else { continue }
            let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String ?? "image/png"
            return GeneratedImage(data: bytes, mimeType: mime)
        }

        // 200 with no image is usually a refusal, explained in a text part.
        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw SpriteGeneratorError.noImageReturned(text.isEmpty ? nil : text)
    }

    static func mapFailure(status: Int, body: Data) -> SpriteGeneratorError {
        let message = Self.message(fromError: body)
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .server(status)
        default: return .badRequest(message ?? "HTTP \(status)")
        }
    }

    /// Google's envelope is `{"error":{"message":…}}`. Falls back to nil so the
    /// caller can substitute a status-based message.
    static func message(fromError data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = root["error"] as? String, !message.isEmpty { return message }
        return nil
    }
}
