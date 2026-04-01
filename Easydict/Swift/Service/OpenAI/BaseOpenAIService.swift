//
//  BaseOpenAIService.swift
//  Easydict
//
//  Created by tisfeng on 2024/3/28.
//  Copyright © 2024 izual. All rights reserved.
//

import AsyncAlgorithms
import Foundation
import OpenAI

// MARK: - BaseOpenAIService

@objcMembers
@objc(EZBaseOpenAIService)
public class BaseOpenAIService: StreamService {
    /// Cancels any active translation stream and stops a pending non-streaming request.
    /// 
    /// Cancels the internal streaming control and, if a non-streaming Task is in flight, cancels it and clears the stored reference.

    open override func cancelStream() {
        control.cancel()
        nonStreamingTask?.cancel()
        nonStreamingTask = nil
    }

    // MARK: Internal

    typealias OpenAIChatMessage = ChatQuery.ChatCompletionMessageParam

    let control = StreamControl()

    /// Temporary override for streaming during validate retry. `nil` means use the persisted value.
    private var streamingOverride: Bool?

    /// Reference to the in-flight non-streaming task so `cancelStream()` can cancel it.
    private var nonStreamingTask: Task<Void, Never>?

    /// Creates a stream that yields translated content for the given text from a source language to a target language.
    /// 
    /// The method validates the configured endpoint and (when required) the API key, builds a chat query from the provided text and language pair, and then either:
    /// - uses the service's streaming API to produce incremental content chunks, or
    /// - performs a single-shot non-streaming request that yields the full translated content as a single chunk.
    /// The choice between streaming and non-streaming is governed by `streamingOverride ?? enableStreaming`.
    /// - Parameters:
    ///   - text: The text to translate.
    ///   - from: Source language.
    ///   - to: Target language.
    /// - Returns: An AsyncThrowingStream that yields translated content chunks as `String`; the stream completes when translation finishes.
    /// - Throws: `QueryError` when the endpoint is invalid (`.parameter`), the API key is missing when required (`.missingSecretKey`), chat message conversion fails (`.parameter`), or when remote request/response errors occur (e.g., `.api`, `.noResult`).
    override func contentStreamTranslate(
        _ text: String,
        from: Language,
        to: Language
    )
        -> AsyncThrowingStream<String, any Error> {
        let url = URL(string: endpoint)

        // Check endpoint
        guard let url, url.isValid else {
            let invalidURLError = QueryError(
                type: .parameter, message: "`\(serviceType().rawValue)` endpoint is invalid"
            )
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: invalidURLError)
            }
        }

        // Check API key if required
        if apiKeyRequirement().requiresKeyForRequest, apiKey.isEmpty {
            let error = QueryError(type: .missingSecretKey, message: "API key is empty")
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        result.isStreamFinished = false

        let queryType = queryType(text: text, from: from, to: to)
        let chatQueryParam = ChatQueryParam(
            text: text,
            sourceLanguage: from,
            targetLanguage: to,
            queryType: queryType,
            enableSystemPrompt: true
        )

        let chatHistory = serviceChatMessageModels(chatQueryParam)
        guard let chatHistory = chatHistory as? [OpenAIChatMessage] else {
            let error = QueryError(
                type: .parameter, message: "Failed to convert chat messages"
            )
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let query = ChatQuery(messages: chatHistory, model: model, temperature: temperature)

        let useStreaming = streamingOverride ?? enableStreaming
        if useStreaming {
            let openAI = OpenAI(apiToken: apiKey)

            // FIXME: It seems that `control` will cause a memory leak, but it is not clear how to solve it.
            unowned let unownedControl = control

            let chatStream: AsyncThrowingStream<ChatStreamResult, Error> = openAI.chatsStream(
                query: query,
                url: url,
                control: unownedControl
            )
            return chatStreamToContentStream(chatStream)
        } else {
            return nonStreamingTranslate(query: query, url: url)
        }
    }

    /// Validates the service, automatically falling back to non-streaming if the endpoint
    /// Validates the service configuration, retrying without streaming if validation fails due to a content-type mismatch.
    /// 
    /// If the initial validation fails with a `QueryError` of type `.contentTypeMismatch` while streaming is enabled, this method retries validation with streaming temporarily disabled. If the retry succeeds, streaming is persisted as disabled and the returned result contains a localized success message indicating streaming was disabled.
    /// - Returns: A `QueryResult` describing the final validation outcome. If the non-streaming retry succeeds, the returned result reflects the retry; otherwise the original validation result is returned.
    override func validate() async -> QueryResult {
        let result = await super.validate()

        guard let queryError = result.error as? QueryError,
              queryError.type == .contentTypeMismatch,
              enableStreaming
        else {
            return result
        }

        // Retry without streaming using a temporary override (not persisted yet).
        logInfo("Streaming validation failed with content-type mismatch, retrying without streaming...")
        streamingOverride = false
        let retryResult = await super.validate()
        streamingOverride = nil

        if retryResult.error != nil {
            // Non-streaming also failed — return the original error which has better diagnostics
            // (e.g. "text/html → check your URL" is more helpful than a generic retry failure).
            return result
        }

        // Non-streaming succeeded — now persist the change and notify user.
        enableStreaming = false
        logInfo("Non-streaming validation succeeded, streaming auto-disabled.")
        retryResult.validationMessage = String(
            localized: "service.configuration.validation_success.streaming_disabled"
        )
        return retryResult
    }

    /// Converts the chat query's message dictionaries into `OpenAIChatMessage` model instances.
    /// 
    /// Only messages that can be mapped to a valid `OpenAIChatMessage.Role` and constructed as `OpenAIChatMessage` are included; invalid or unconvertible messages are skipped.
    /// - Parameter chatQuery: The chat query parameters whose message dictionaries will be converted.
    /// - Returns: An array containing the successfully constructed `OpenAIChatMessage` objects (typed as `[Any]`).
    override func serviceChatMessageModels(_ chatQuery: ChatQueryParam) -> [Any] {
        var chatMessages: [OpenAIChatMessage] = []
        for message in chatMessageDicts(chatQuery) {
            let openAIRole = message.role.rawValue
            let content = message.content

            if let role = OpenAIChatMessage.Role(rawValue: openAIRole),
               let chat = OpenAIChatMessage(role: role, content: content) {
                chatMessages.append(chat)
            }
        }
        return chatMessages
    }

    // MARK: Private

    /// Performs a single-shot (non-streaming) chat completion request and exposes the full response content as a single-streamed value.
    /// 
    /// The function issues an HTTP POST with a JSON-encoded `ChatQuery` (sent with `stream = false`). If `apiKey` is non-empty the request includes an `Authorization: Bearer <apiKey>` header. On a successful 2xx response the body is decoded as `ChatResult` and the first non-empty `choices.first?.message.content?.string` is yielded as a single stream element; if no content is present a `QueryError(type: .noResult)` is thrown. For non-2xx responses the implementation first attempts to decode `APIErrorResponse` and throws it if successful, otherwise it throws a `QueryError(type: .api, ...)` that includes the HTTP status and response body text. The returned stream is cancelled cleanly if the underlying task is cancelled or the stream terminates; the running `Task` is stored in `nonStreamingTask` so it can be cancelled by `cancelStream()`.
    /// - Parameters:
    ///   - query: The chat query to send (will be sent with `stream = false`).
    ///   - url: The request endpoint URL.
    /// - Returns: An `AsyncThrowingStream<String, Error>` that yields the complete response content as a single `String` or finishes by throwing an error.
    private func nonStreamingTranslate(
        query: ChatQuery,
        url: URL
    )
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            let task = Task {
                do {
                    var query = query
                    query.stream = false

                    var request = URLRequest(url: url, timeoutInterval: EZNetWorkTimeoutInterval)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !self.apiKey.isEmpty {
                        request.setValue(
                            "Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization"
                        )
                    }
                    request.httpBody = try JSONEncoder().encode(query)

                    let (data, response) = try await URLSession.shared.data(for: request)
                    try Task.checkCancellation()

                    if let http = response as? HTTPURLResponse,
                       !(200 ... 299).contains(http.statusCode)
                    {
                        if let apiError = try? JSONDecoder().decode(
                            APIErrorResponse.self, from: data
                        ) {
                            throw apiError
                        }
                        throw QueryError(
                            type: .api,
                            message: "HTTP \(http.statusCode)",
                            errorDataMessage: String(data: data, encoding: .utf8)
                        )
                    }

                    let chatResult = try JSONDecoder().decode(ChatResult.self, from: data)
                    if let content = chatResult.choices.first?.message.content?.string,
                       !content.isEmpty
                    {
                        continuation.yield(content)
                        continuation.finish()
                    } else {
                        throw QueryError(type: .noResult)
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            self?.nonStreamingTask = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
