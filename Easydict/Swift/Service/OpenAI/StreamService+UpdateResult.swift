//
//  StreamService+UpdateResult.swift
//  Easydict
//
//  Created by tisfeng on 2025/1/18.
//  Copyright © 2025 izual. All rights reserved.
//

import Foundation
import RegexBuilder

extension StreamService {
    /// Get final result text, remove redundant content, like tag and qoutes.
    func getFinalResultText(_ text: String) -> String {
        var resultText = text.trim()

        // Remove last </s>, fix Groq model mixtral-8x7b-32768
        let stopFlag = "</s>"
        if !queryModel.queryText.hasSuffix(stopFlag), resultText.hasSuffix(stopFlag) {
            resultText = String(resultText.dropLast(stopFlag.count)).trim()
        }

        // Since it is more difficult to accurately remove redundant quotes in streaming, we wait until the end of the request to remove the quotes
        resultText = resultText.tryToRemoveQuotes().trim()

        return resultText
    }

    /// Throttle update result text, avoid update UI too frequently.
    func throttleUpdateResultText(
        _ textStream: AsyncThrowingStream<String, Error>,
        queryType: EZQueryTextType,
        error: Error?,
        interval: TimeInterval = 0.3,
        completion: @escaping (QueryResult) -> ()
    ) async throws {
        for try await text in textStream._throttle(for: .seconds(interval)) {
            updateResultText(text, queryType: queryType, error: error, completion: completion)
        }
    }

    /// Update the shared query result with the latest streamed text, finalize state when the stream completes, and invoke the provided completion with the resulting `QueryResult`.
    /// 
    /// When the stream is already marked finished this function cancels the stream and determines a `QueryError` to report (suppresses user cancellations and may classify or ignore other completion errors based on content). Otherwise it updates `result.isStreamFinished` when an `error` is present, trims and optionally filters `resultText`, assigns the finalized text to `result.translatedResults`, adjusts dictionary-specific UI flags, and completes via the `completion` closure. The result's `.error` property is set with `.queryError(from:)` before invoking `completion`.
    /// - Parameters:
    ///   - resultText: The latest streamed text chunk (may be partial or nil); will be trimmed and filtered according to settings before being stored.
    ///   - queryType: The query presentation type; `.dictionary` toggles dictionary-specific layout flags when finalizing results.
    ///   - error: An optional error indicating stream completion; a non-nil value marks the stream finished. User-cancellation errors are suppressed and some completion errors may be ignored or reclassified.
    ///   - completion: Callback invoked with the updated `QueryResult`.
    func updateResultText(
        _ resultText: String?,
        queryType: EZQueryTextType,
        error: Error?,
        completion: @escaping (QueryResult) -> ()
    ) {
        // Acquire the lock before accessing/modifying the shared 'result' state
        updateResultLock.lock()
        defer { updateResultLock.unlock() }

        if result.isStreamFinished {
            cancelStream()

            var queryError: QueryError?

            if let error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    // Do not throw error if user cancelled request.
                } else if shouldIgnoreCompletionError(error, resultText: resultText) {
                    logInfo("Ignore stream completion error with existing content: \(error)")
                } else {
                    queryError = classifiedQueryError(from: error)
                }
            } else if resultText?.isEmpty ?? true {
                // If error is nil but result text is also empty, we should report error.
                queryError = .init(type: .noResult)
            }

            completeWithResult(result, error: queryError)
            return
        }

        // If error is not nil, means stream is finished.
        result.isStreamFinished = error != nil

        var finalText = resultText?.trim() ?? ""

        if hideThinkTagContent {
            finalText = finalText.filterThinkTagContent().trim()
        }

        let updateCompletion = { [weak result] in
            guard let result else { return }

            result.translatedResults = [finalText]
            completeWithResult(result, error: error)
        }

        switch queryType {
        case .dictionary:
            if error != nil {
                result.showBigWord = false
                result.translateResultsTopInset = 0
                updateCompletion()
                return
            }

            result.showBigWord = true
            result.translateResultsTopInset = 6
            updateCompletion()

        default:
            updateCompletion()
        }

        func completeWithResult(_ result: QueryResult, error: Error?) {
            result.error = .queryError(from: error)
            completion(result)
        }
    }

    /// Determines whether a completion error can be ignored when the streamed result already contains sufficient content and the error indicates a content-type mismatch.
    /// - Parameters:
    ///   - error: The error to inspect for content-type mismatch context (may contain nested/underlying error information).
    ///   - resultText: The accumulated result text used to assess content sufficiency.
    /// - Returns: `true` if `resultText` contains at least 8 characters and the error context shows a content-type mismatch for a known MIME (`text/plain` or `application/json`); `false` otherwise.
    private func shouldIgnoreCompletionError(_ error: Error, resultText: String?) -> Bool {
        guard let resultText else {
            return false
        }

        let trimmedText = resultText.trim()
        guard !trimmedText.isEmpty else {
            return false
        }

        let contentLength = trimmedText.count
        let minContentLengthToSuppressError = 8
        guard contentLength >= minContentLengthToSuppressError else {
            logInfo(
                "Do not ignore stream completion error due to insufficient content. " +
                    "Content length: \(contentLength), error: \(error)"
            )
            return false
        }

        // This error can be wrapped by different layers, so we collect a compact context string
        // from the error itself, NSError metadata, and nested underlying errors.
        let lowercasedErrorContext = errorContextString(error).lowercased()

        let isContentTypeError = isContentTypeMismatchContext(lowercasedErrorContext)
        let isKnownMIME = lowercasedErrorContext.contains("text/plain")
            || lowercasedErrorContext.contains("application/json")
        let shouldSuppress = isContentTypeError && isKnownMIME

        if shouldSuppress {
            logInfo(
                "Ignore stream completion error with existing content due to content-type mismatch. " +
                    "Content length: \(contentLength), error: \(error)"
            )
        }

        return shouldSuppress
    }

    /// Maps an `Error` to a user-facing `QueryError`, producing content-type-specific messages when the error context indicates a content-type mismatch.
    /// - Returns: A `QueryError` representing the classified error. If the error context indicates a content-type mismatch, returns a `.contentTypeMismatch` `QueryError` with localized messages tailored for `text/html`, `application/json`, or an unknown content type. Otherwise returns `.queryError(from: error)` if available, or a `QueryError(type: .api)` fallback.
    private func classifiedQueryError(from error: Error) -> QueryError {
        let context = errorContextString(error).lowercased()

        if isContentTypeMismatchContext(context) {
            if context.contains("text/html") {
                return QueryError(
                    type: .contentTypeMismatch,
                    message: String(localized: "error.content_type.html"),
                    errorDataMessage: String(localized: "error.content_type.html.suggestion")
                )
            }
            if context.contains("application/json") {
                return QueryError(
                    type: .contentTypeMismatch,
                    message: String(localized: "error.content_type.json"),
                    errorDataMessage: String(localized: "error.content_type.json.suggestion")
                )
            }
            return QueryError(
                type: .contentTypeMismatch,
                message: String(localized: "error.content_type.unknown"),
                errorDataMessage: String(localized: "error.content_type.unknown.suggestion")
            )
        }

        // queryError(from:) always returns non-nil for a non-nil error.
        .queryError(from: error) ?? QueryError(type: .api)
    }

    /// Determines whether the provided error context string indicates an HTTP content-type mismatch.
    /// - Parameter context: A normalized (typically lowercased) error context string to inspect.
    /// - Returns: `true` if the context contains indicators of a content-type mismatch, `false` otherwise.
    private func isContentTypeMismatchContext(_ context: String) -> Bool {
        context.contains("incorrectcontenttype(")
            || context.contains("incorrect content-type:")
            || context.contains("unacceptable content-type:")
    }

    /// Builds a compact, de-duplicated string containing human-readable context extracted from an `Error`.
    /// 
    /// The returned string aggregates the error's `description`, `localizedDescription`, `localizedFailureReason`,
    /// `localizedRecoverySuggestion`, any debug description found in `userInfo[NSDebugDescriptionErrorKey]`, and
    /// response body text stored under `com.alamofire.serialization.response.error.data` (if UTF-8 decodable). It
    /// also traverses an underlying error chain up to two levels to include context from wrapped errors.
    /// - Parameter error: The error to extract context from.
    /// - Returns: A single string with distinct context fragments joined by " | ".
    private func errorContextString(_ error: Error) -> String {
        var parts = Set<String>()

        func collect(_ currentError: Error, depth: Int) {
            guard depth <= 2 else {
                return
            }

            let nsError = currentError as NSError
            parts.insert(String(describing: currentError))
            parts.insert(nsError.localizedDescription)

            if let failureReason = nsError.localizedFailureReason {
                parts.insert(failureReason)
            }

            if let recoverySuggestion = nsError.localizedRecoverySuggestion {
                parts.insert(recoverySuggestion)
            }

            if let debugDescription = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
                parts.insert(debugDescription)
            }

            if let responseData = nsError.userInfo["com.alamofire.serialization.response.error.data"] as? Data,
               let responseText = String(data: responseData, encoding: .utf8) {
                parts.insert(responseText)
            }

            if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                collect(underlyingError, depth: depth + 1)
            }
        }

        collect(error, depth: 0)
        return parts.joined(separator: " | ")
    }
}
