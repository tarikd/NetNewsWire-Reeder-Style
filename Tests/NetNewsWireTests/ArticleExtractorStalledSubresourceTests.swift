import XCTest
import Network
@testable import NetNewsWire

/// Reader View extraction must not depend on every subresource of a page
/// finishing. When a host silently drops connections — an IPv4-only ad or
/// tracker host reached from an IPv6-only network, say — the page's load event
/// is held up for 30 seconds, long after the article itself has arrived.
@MainActor final class ArticleExtractorStalledSubresourceTests: XCTestCase {

	func testExtractsArticleWhileSubresourceNeverResponds() async throws {
		let extractedArticle = try await extract(path: StalledSubresourceServer.articleWithStalledImagePath)

		let content = try XCTUnwrap(extractedArticle.content)
		XCTAssertTrue(content.contains("harbour ferry"))
	}

	func testExtractsArticleWhenPageFinishesLoading() async throws {
		let extractedArticle = try await extract(path: StalledSubresourceServer.articlePath)

		let content = try XCTUnwrap(extractedArticle.content)
		XCTAssertTrue(content.contains("harbour ferry"))
	}
}

private extension ArticleExtractorStalledSubresourceTests {

	/// Well under the extractor's own timeout, so waiting that timeout out counts as a failure.
	static let patience: TimeInterval = 15

	func extract(path: String) async throws -> ExtractedArticle {
		let server = try await StalledSubresourceServer.start()
		let recorder = ExtractionRecorder()
		let extractor = try XCTUnwrap(ArticleExtractor(server.url(path: path), delegate: recorder))
		defer {
			extractor.cancel()
			server.stop()
		}

		extractor.process()
		await fulfillment(of: [recorder.finished], timeout: Self.patience)

		if let error = recorder.error {
			throw error
		}
		return try XCTUnwrap(recorder.extractedArticle)
	}
}

@MainActor private final class ExtractionRecorder: ArticleExtractorDelegate {

	let finished = XCTestExpectation(description: "Extraction finished")
	private(set) var extractedArticle: ExtractedArticle?
	private(set) var error: Error?

	func articleExtractionDidFail(with error: Error) {
		self.error = error
		finished.fulfill()
	}

	func articleExtractionDidComplete(extractedArticle: ExtractedArticle) {
		self.extractedArticle = extractedArticle
		finished.fulfill()
	}
}

/// A loopback HTTP server that serves an article page and accepts — but never
/// answers — every other request, the way an unreachable host behaves.
private final class StalledSubresourceServer: @unchecked Sendable {

	static let articlePath = "/article"
	static let articleWithStalledImagePath = "/article-with-stalled-image"

	private let listener: NWListener
	private let queue = DispatchQueue(label: "StalledSubresourceServer")
	private var connections = [NWConnection]() // Only touched on queue.

	private init(listener: NWListener) {
		self.listener = listener
	}

	static func start() async throws -> StalledSubresourceServer {
		let parameters = NWParameters.tcp
		parameters.acceptLocalOnly = true
		let server = StalledSubresourceServer(listener: try NWListener(using: parameters))
		try await server.startListening()
		return server
	}

	func url(path: String) -> String {
		"http://127.0.0.1:\(listener.port?.rawValue ?? 0)\(path)"
	}

	func stop() {
		queue.async {
			self.listener.cancel()
			for connection in self.connections {
				connection.cancel()
			}
			self.connections.removeAll()
		}
	}

	private func startListening() async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			listener.stateUpdateHandler = { state in
				switch state {
				case .ready:
					self.listener.stateUpdateHandler = nil
					continuation.resume()
				case .failed(let error):
					self.listener.stateUpdateHandler = nil
					continuation.resume(throwing: error)
				default:
					break
				}
			}
			listener.newConnectionHandler = { connection in
				self.accept(connection)
			}
			listener.start(queue: queue)
		}
	}

	private func accept(_ connection: NWConnection) {
		connections.append(connection)
		connection.start(queue: queue)
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
			guard let data, let request = String(data: data, encoding: .utf8) else {
				return
			}
			guard let html = Self.html(forRequest: request) else {
				// Not a page we serve. Keep the connection open and say nothing.
				return
			}
			let body = Data(html.utf8)
			let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
			connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
				connection.cancel()
			})
		}
	}

	private static func html(forRequest request: String) -> String? {
		if request.hasPrefix("GET \(articleWithStalledImagePath) ") {
			return articleHTML(extra: "<img src=\"/stalled.png\" width=\"1\" height=\"1\">")
		}
		if request.hasPrefix("GET \(articlePath) ") {
			return articleHTML(extra: "")
		}
		return nil
	}

	private static func articleHTML(extra: String) -> String {
		let sentence = "The harbour ferry left on time this morning, carrying commuters, cyclists and a delivery of fresh bread across the bay while gulls circled the stern. "
		let paragraphs = String(repeating: "<p>" + String(repeating: sentence, count: 3) + "</p>", count: 6)
		return """
		<!doctype html>
		<html>
		<head><meta charset="utf-8"><title>Ferry service resumes across the bay</title></head>
		<body>
		<article><h1>Ferry service resumes across the bay</h1>\(paragraphs)</article>
		\(extra)
		</body>
		</html>
		"""
	}
}
