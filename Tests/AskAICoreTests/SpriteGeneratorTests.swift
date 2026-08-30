import Testing
import Foundation
@testable import AskAICore

private func responseJSON(
    mime: String = "image/jpeg", base64: String, snakeCase: Bool = false
) -> Data {
    let key = snakeCase ? "inline_data" : "inlineData"
    let mimeKey = snakeCase ? "mime_type" : "mimeType"
    let json = """
        {"candidates":[{"content":{"parts":[
          {"\(key)":{"\(mimeKey)":"\(mime)","data":"\(base64)"}}
        ]}}]}
        """
    return Data(json.utf8)
}

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

@Suite("Gemini image client", .serialized)
struct GeminiImageClientTests {

    private func makeClient(key: String? = "test-key") -> GeminiImageClient {
        GeminiImageClient(apiKey: key, session: StubURLProtocol.makeSession())
    }

    @Test("a successful response yields the image bytes and its mime type")
    func success() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            status: 200, body: responseJSON(base64: pngBytes.base64EncodedString()))

        let image = try await makeClient().generate(prompt: "a robot")
        #expect(image.data == pngBytes)
        #expect(image.mimeType == "image/jpeg")
    }

    /// Format follows the model, so the client must report what it was given
    /// rather than assuming PNG.
    @Test("the reported mime type is not assumed")
    func mimeTypeIsCarried() throws {
        let png = try GeminiImageClient.image(
            fromResponse: responseJSON(
                mime: "image/png", base64: pngBytes.base64EncodedString()))
        #expect(png.mimeType == "image/png")
    }

    @Test("snake_case and camelCase payloads both decode")
    func bothSpellings() throws {
        let camel = try GeminiImageClient.image(
            fromResponse: responseJSON(base64: pngBytes.base64EncodedString()))
        let snake = try GeminiImageClient.image(
            fromResponse: responseJSON(
                base64: pngBytes.base64EncodedString(), snakeCase: true))
        #expect(camel.data == snake.data)
    }

    @Test("the request carries the Google auth header and the model in the path")
    func requestShape() throws {
        let request = try makeClient().makeRequest(prompt: "a robot", reference: nil)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        // Not Bearer: the OpenAI-compatible client talks to the same host with
        // different auth, and mixing them up would 401 confusingly.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasSuffix("/gemini-3-pro-image-preview:generateContent"))
    }

    @Test("a reference image is sent inline alongside the prompt")
    func referenceIsAttached() throws {
        let reference = GeneratedImage(data: pngBytes, mimeType: "image/png")
        let request = try makeClient().makeRequest(prompt: "walk cycle", reference: reference)
        let body = try #require(request.httpBody)
        let root = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(root["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.count == 2)
        // Image first, instruction second.
        #expect(parts[0]["inline_data"] != nil)
        #expect(parts[1]["text"] != nil)
    }

    @Test("no key fails before any request is made")
    func missingKey() async {
        StubURLProtocol.reset()
        await #expect(throws: SpriteGeneratorError.missingAPIKey) {
            try await self.makeClient(key: nil).generate(prompt: "x")
        }
        await #expect(throws: SpriteGeneratorError.missingAPIKey) {
            try await self.makeClient(key: "").generate(prompt: "x")
        }
    }

    @Test("401 and 403 both read as a rejected key")
    func unauthorized() async {
        for status in [401, 403] {
            StubURLProtocol.reset()
            StubURLProtocol.stub = .init(status: status, body: Data("{}".utf8))
            await #expect(throws: SpriteGeneratorError.unauthorized) {
                try await self.makeClient().generate(prompt: "x")
            }
        }
    }

    @Test("429 is rate limiting and is retryable")
    func rateLimited() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 429, body: Data("{}".utf8))
        await #expect(throws: SpriteGeneratorError.rateLimited) {
            try await self.makeClient().generate(prompt: "x")
        }
        #expect(SpriteGeneratorError.rateLimited.isRetryable)
    }

    @Test("5xx is reported with its status")
    func serverError() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 503, body: Data("{}".utf8))
        await #expect(throws: SpriteGeneratorError.server(503)) {
            try await self.makeClient().generate(prompt: "x")
        }
    }

    /// The 400 that started all this: both documented ways to request PNG are
    /// rejected by the real API, and the message is the only useful part.
    @Test("a 400 surfaces the service's own message")
    func badRequestMessage() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(
            status: 400,
            body: Data(#"{"error":{"message":"Unknown name \"imageOutputOptions\""}}"#.utf8))
        do {
            _ = try await makeClient().generate(prompt: "x")
            Issue.record("expected a failure")
        } catch let error as SpriteGeneratorError {
            #expect(error.userMessage.contains("imageOutputOptions"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("malformed JSON is a decoding failure, not a crash")
    func malformed() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .init(status: 200, body: Data("not json".utf8))
        await #expect(throws: SpriteGeneratorError.decoding) {
            try await self.makeClient().generate(prompt: "x")
        }
    }

    /// A safety refusal arrives as 200 with a text part and no image. Showing
    /// the model's own explanation beats "no image returned".
    @Test("200 with no image surfaces the model's explanation")
    func refusalCarriesText() {
        let body = Data(
            #"{"candidates":[{"content":{"parts":[{"text":"I can't create that."}]}}]}"#.utf8)
        do {
            _ = try GeminiImageClient.image(fromResponse: body)
            Issue.record("expected a failure")
        } catch let error as SpriteGeneratorError {
            #expect(error == .noImageReturned("I can't create that."))
            #expect(error.userMessage.contains("I can't create that."))
            #expect(!error.isRetryable, "a refusal will not succeed on retry")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("a response with no parts at all is a decoding failure")
    func noParts() {
        #expect(throws: SpriteGeneratorError.decoding) {
            try GeminiImageClient.image(fromResponse: Data(#"{"candidates":[]}"#.utf8))
        }
    }

    @Test("undecodable base64 is skipped rather than returned as empty data")
    func badBase64() {
        let body = responseJSON(base64: "!!!not-base64!!!")
        #expect(throws: (any Error).self) {
            try GeminiImageClient.image(fromResponse: body)
        }
    }
}

// MARK: - Prompts and job wiring

/// Returns a fixed image for every call, and records what it was asked.
private final class FakeGenerator: SpriteGeneratorClient, @unchecked Sendable {
    var prompts: [String] = []
    var references: [GeneratedImage?] = []
    var failAfter: Int?

    let image = GeneratedImage(data: Data([1, 2, 3]), mimeType: "image/jpeg")

    func generate(prompt: String) async throws -> GeneratedImage {
        try record(prompt, nil)
    }
    func generate(prompt: String, reference: GeneratedImage) async throws -> GeneratedImage {
        try record(prompt, reference)
    }
    private func record(_ prompt: String, _ reference: GeneratedImage?) throws -> GeneratedImage {
        if let failAfter, prompts.count >= failAfter { throw SpriteGeneratorError.rateLimited }
        prompts.append(prompt)
        references.append(reference)
        return image
    }
}

@Suite("Sprite generation job")
struct SpriteGenerationJobTests {

    /// A 2x3 and a 2x2 grid of dark squares on white, so the real extractor runs.
    private func fakeSheet(columns: Int, rows: Int) -> PixelBitmap {
        var bitmap = PixelBitmap(width: columns * 100, height: rows * 100)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width { bitmap[x, y] = (255, 255, 255, 255) }
        }
        for row in 0..<rows {
            for column in 0..<columns {
                for y in (row * 100 + 30)..<(row * 100 + 70) {
                    for x in (column * 100 + 30)..<(column * 100 + 70) {
                        bitmap[x, y] = (10, 10, 10, 255)
                    }
                }
            }
        }
        return bitmap
    }

    private func run(client: FakeGenerator) async throws -> SpriteGenerationJob.Output {
        var call = 0
        let job = SpriteGenerationJob(client: client, encoder: { _ in Data([9, 9]) })
        return try await job.run(
            id: "robot", name: "Robot", description: "a robot",
            decode: { _ in
                // First sheet is the 3x2 walk, second the 2x2 poses.
                call += 1
                return call == 1 ? self.fakeSheet(columns: 3, rows: 2)
                                 : self.fakeSheet(columns: 2, rows: 2)
            })
    }

    @Test("generates a character then one sheet per animation")
    func callSequence() async throws {
        let client = FakeGenerator()
        _ = try await run(client: client)
        #expect(client.prompts.count == 3, "character + walk + poses")
        #expect(client.references[0] == nil, "the character has no reference")
        // Identity: every sheet is generated from the character image.
        #expect(client.references[1] != nil)
        #expect(client.references[2] != nil)
    }

    @Test("produces frames for every mood the panel needs")
    func producesAllMoods() async throws {
        let output = try await run(client: FakeGenerator())
        for mood in SpriteMood.allCases {
            #expect(output.set.animations[mood.rawValue] != nil, "\(mood) missing")
        }
        #expect(output.frames.count == 10, "6 walk + 4 pose")
        #expect(output.sheets.count == 2)
    }

    /// Reduce Motion shows the resting frame, so a celebration must settle onto
    /// the calm pose rather than freezing mid-cheer.
    @Test("the talking animation settles on the idle pose")
    func talkingSettles() async throws {
        let output = try await run(client: FakeGenerator())
        let talking = try #require(output.set.animations[SpriteMood.talking.rawValue])
        #expect(talking.restingFrame == "pose-0")
        #expect(!talking.loops)
    }

    @Test("only the thinking mood loops, matching the built-in set")
    func onlyThinkingLoops() async throws {
        let output = try await run(client: FakeGenerator())
        for mood in SpriteMood.allCases {
            let animation = try #require(output.set.animations[mood.rawValue])
            #expect(animation.loops == (mood == .thinking), "\(mood)")
        }
    }

    @Test("a failure partway through propagates rather than half-saving")
    func failurePropagates() async {
        let client = FakeGenerator()
        client.failAfter = 1      // character succeeds, first sheet fails
        await #expect(throws: SpriteGeneratorError.rateLimited) {
            _ = try await self.run(client: client)
        }
    }

    @Test("the style suffix is appended but the description is preserved")
    func promptsCarryStyleAndDescription() {
        let walk = SpritePrompts.walk(character: "a tiny dragon")
        #expect(walk.contains("a tiny dragon"))
        #expect(walk.contains("2x3 grid"))
        #expect(walk.contains(SpritePrompts.style))
    }

    /// Both models draw cell borders regardless, so the prompt must not claim to
    /// prevent them — the extractor removes them instead.
    @Test("prompts do not promise the model will omit borders")
    func promptDoesNotAskForNoBorders() {
        #expect(!SpritePrompts.style.lowercased().contains("no border"))
        #expect(!SpritePrompts.style.lowercased().contains("grid line"))
    }
}

@Suite("Image key reuse", .serialized)
struct ImageKeyReuseTests {

    private func settings(baseURL: String) -> (SettingsStore, UserDefaults, String) {
        let name = "askai.imagekey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = SettingsStore(defaults: defaults)
        store.baseURLString = baseURL
        return (store, defaults, name)
    }

    @Test("a Google endpoint means the existing key covers image generation")
    func googleReuses() {
        let (store, defaults, name) = settings(
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(store.llmKeyWorksForImages)
    }

    @Test("other providers need a separate image key")
    func othersDoNot() {
        for url in ["https://api.anthropic.com/v1/messages",
                    "https://api.openai.com/v1/chat/completions",
                    "http://localhost:11434/v1/chat/completions"] {
            let (store, defaults, name) = settings(baseURL: url)
            defer { defaults.removePersistentDomain(forName: name) }
            #expect(!store.llmKeyWorksForImages, "\(url)")
        }
    }

    /// Checked by host, not by the preset id, because the base URL is editable
    /// and the preset is only a UI hint.
    @Test("a lookalike host does not count")
    func lookalikeHostRejected() {
        let (store, defaults, name) = settings(
            baseURL: "https://generativelanguage.googleapis.com.evil.test/v1")
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!store.llmKeyWorksForImages)
    }
}
