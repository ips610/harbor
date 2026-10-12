import XCTest
@testable import Harbor

/// The proxy's handling of one connection: exactly one request goes to the dev server, the
/// answer comes back saying the connection is over, and a raw two-way pipe exists only once
/// the server has agreed to a WebSocket. The exchange is run for real here, between socket
/// pairs inside the test (no ports).
final class ProxyTests: XCTestCase {
    // MARK: A request's body

    private func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }

    func testBodyWithALength() {
        var body = BodyScanner(.length(5))
        XCTAssertEqual(body.take(bytes("hel")), 3)
        XCTAssertFalse(body.isDone)
        XCTAssertEqual(body.take(bytes("loGET /next HTTP/1.1")), 2)               // only what belongs to this request
        XCTAssertTrue(body.isDone)
        XCTAssertEqual(body.take(bytes("more")), 0)
        var none = BodyScanner(.none)
        XCTAssertTrue(none.isDone)
        XCTAssertEqual(none.take(bytes("GET /next HTTP/1.1\r\n\r\n")), 0)           // a request with no body takes nothing
    }

    func testBodyInChunks() {
        let message = "4\r\nWiki\r\n6;ext=1\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\nTrailer: x\r\n\r\n"
        var whole = BodyScanner(.chunked)
        XCTAssertEqual(whole.take(bytes(message + "GET /next HTTP/1.1\r\n\r\n")), message.utf8.count)
        XCTAssertTrue(whole.isDone)
        // The same, arriving a byte at a time.
        var slow = BodyScanner(.chunked)
        var taken = 0
        for byte in Array((message + "EXTRA").utf8) { taken += slow.take([byte][...]) ?? -1000 }
        XCTAssertEqual(taken, message.utf8.count)
        XCTAssertTrue(slow.isDone)
        // Not chunks: refused rather than guessed at.
        for bad in ["zz\r\n", "5\nhello", "5\r\nhelloXX", "-1\r\n", "5 \r\nhello\r\n", "\r\n", String(repeating: "1", count: 20) + "\r\n"] {
            var scanner = BodyScanner(.chunked)
            XCTAssertNil(scanner.take(bytes(bad)), bad)
        }
    }

    // MARK: The server's answer

    func testAnswerSaysTheConnectionIsOver() {
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nSet-Cookie: a=b\r\n\r\n".utf8)
        let out = String(decoding: ResponseHead.closing(head), as: UTF8.self)
        XCTAssertEqual(out, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nSet-Cookie: a=b\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(ResponseHead.status(head), 200)
        XCTAssertEqual(ResponseHead.status(Data("HTTP/1.0 404 Not Found\r\n\r\n".utf8)), 404)
        XCTAssertEqual(ResponseHead.status(Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8)), 101)
        XCTAssertNil(ResponseHead.status(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))
        XCTAssertNil(ResponseHead.status(Data("HTTP/1.1 OK\r\n\r\n".utf8)))
    }

    // MARK: The exchange, end to end

    private struct Wire {
        let client: Int32    // the test's end, playing the browser
        let server: Int32    // the test's end, playing the dev server
        let done: XCTestExpectation
    }

    /// Runs `Proxy.exchange` on its own thread between two socket pairs and hands back the far ends.
    private func exchange(_ request: String, rest: String = "", idle: Double = 5, quietSocket: Double? = nil) throws -> Wire {
        var c: [Int32] = [0, 0], s: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &c), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &s), 0)
        for fd in [c[1], s[1]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        for fd in c + s { var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let head = try XCTUnwrap(ProxyHead(Data(request.utf8)))
        let done = expectation(description: "exchange ends")
        Thread.detachNewThread {
            Proxy.exchange(client: c[1], server: s[1], request: head, rest: Data(rest.utf8), clientAddress: "127.0.0.1", idle: idle, quietSocket: quietSocket)
            close(c[1]); close(s[1])
            done.fulfill()
        }
        return Wire(client: c[0], server: s[0], done: done)
    }

    private func send(_ fd: Int32, _ text: String) { _ = Array(text.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) } }

    /// Reads until `marker` has arrived, the other side closed, or 2 s passed.
    private func read(_ fd: Int32, until marker: String? = nil) -> String {
        var out = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { if marker == nil, !out.isEmpty { continue }; continue }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            out += chunk[0..<n]
            if let marker, String(decoding: out, as: UTF8.self).contains(marker) { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// True when nothing arrives on `fd` for a quarter of a second.
    private func silent(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 250) == 0
    }

    func testASecondRequestNeverReachesTheServer() throws {
        // Two requests sent in one go on one connection.
        let first = "GET /one HTTP/1.1\r\nHost: storefront.localhost\r\nConnection: keep-alive\r\n\r\n"
        let wire = try exchange(first, rest: "GET /two HTTP/1.1\r\nHost: evil.localhost\r\n\r\n")
        let got = read(wire.server, until: "\r\n\r\n")
        XCTAssertTrue(got.hasPrefix("GET /one HTTP/1.1\r\nHost: storefront.localhost\r\n"), got)
        XCTAssertTrue(got.contains("\r\nConnection: close\r\n"))
        XCTAssertFalse(got.contains("/two"))
        // More from the client, later: still nothing for the server.
        send(wire.client, "GET /three HTTP/1.1\r\nHost: storefront.localhost\r\n\r\n")
        XCTAssertTrue(silent(wire.server))
        // The answer says the connection is over, whatever the server said, and its body streams through.
        send(wire.server, "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nContent-Length: 5\r\n\r\nhello")
        let answer = read(wire.client, until: "hello")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 200 OK\r\n"), answer)
        XCTAssertTrue(answer.contains("\r\nConnection: close\r\n"))
        XCTAssertFalse(answer.lowercased().contains("keep-alive"))
        XCTAssertTrue(answer.hasSuffix("\r\n\r\nhello"))
        XCTAssertTrue(silent(wire.server))                                         // and /three never went anywhere
        close(wire.server)
        wait(for: [wire.done], timeout: 5)
        close(wire.client)
    }

    func testExactlyTheBodyIsPassedOn() throws {
        // A body with a length: its bytes, and not what follows them.
        let wire = try exchange("POST /save HTTP/1.1\r\nHost: storefront.localhost\r\nContent-Length: 11\r\n\r\n", rest: "hello ")
        send(wire.client, "worldGET /smuggled HTTP/1.1\r\nHost: storefront.localhost\r\n\r\n")
        let got = read(wire.server, until: "world")
        XCTAssertTrue(got.hasSuffix("\r\n\r\nhello world"), got)
        XCTAssertTrue(silent(wire.server))
        XCTAssertFalse(read(wire.server).contains("smuggled"))
        close(wire.server)
        wait(for: [wire.done], timeout: 5)
        close(wire.client)

        // The same in chunks.
        let chunks = "5\r\nhello\r\n0\r\n\r\n"
        let chunked = try exchange("POST /save HTTP/1.1\r\nHost: storefront.localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        send(chunked.client, chunks + "GET /smuggled HTTP/1.1\r\nHost: storefront.localhost\r\n\r\n")
        let body = read(chunked.server, until: "0\r\n\r\n")
        XCTAssertTrue(body.hasSuffix("\r\n\r\n" + chunks), body)
        XCTAssertTrue(silent(chunked.server))
        close(chunked.server)
        wait(for: [chunked.done], timeout: 5)
        close(chunked.client)
    }

    func testAskingForAWebSocketIsNotEnough() throws {
        // The client claims an upgrade; the server answers an ordinary 200.
        let wire = try exchange("GET /hmr HTTP/1.1\r\nHost: storefront.localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", idle: 1)
        XCTAssertTrue(read(wire.server, until: "\r\n\r\n").contains("\r\nConnection: Upgrade\r\n"))
        send(wire.server, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno")
        let answer = read(wire.client, until: "no")
        XCTAssertTrue(answer.contains("\r\nConnection: close\r\n"), answer)
        // No pipe: what the client sends now goes nowhere, and the idle limit still applies.
        send(wire.client, "raw bytes that would be frames")
        XCTAssertTrue(silent(wire.server))
        wait(for: [wire.done], timeout: 4)                                         // ended by the 1 s idle limit, nobody closed
        close(wire.client); close(wire.server)
    }

    func testAWebSocketOnceTheServerAgrees() throws {
        let wire = try exchange("GET /hmr HTTP/1.1\r\nHost: storefront.localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", idle: 0.5)
        _ = read(wire.server, until: "\r\n\r\n")
        send(wire.server, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        let answer = read(wire.client, until: "\r\n\r\n")
        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 101"), answer)
        XCTAssertTrue(answer.contains("\r\nConnection: Upgrade\r\n"))              // untouched
        XCTAssertFalse(answer.contains("Connection: close"))
        // A pipe both ways now, and it outlives the idle limit (0.5 s here).
        usleep(900_000)
        send(wire.client, "frame from the page")
        XCTAssertEqual(read(wire.server, until: "page"), "frame from the page")
        send(wire.server, "frame from the server")
        XCTAssertEqual(read(wire.client, until: "server"), "frame from the server")
        close(wire.client)
        wait(for: [wire.done], timeout: 5)
        close(wire.server)
    }

    func testAQuietWebSocketIsClosedWhenTheCallerSaysSo() throws {
        // On the network a WebSocket with nothing passing either way is closed after a while (ten minutes there).
        XCTAssertEqual(OnNetwork(announces: false).quietSocket, 600)
        let wire = try exchange("GET /hmr HTTP/1.1\r\nHost: storefront.local\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", quietSocket: 0.4)
        _ = read(wire.server, until: "\r\n\r\n")
        send(wire.server, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        XCTAssertTrue(read(wire.client, until: "\r\n\r\n").hasPrefix("HTTP/1.1 101 "))
        // While something passes it stays open; then nothing does.
        send(wire.client, "ping")
        XCTAssertEqual(read(wire.server, until: "ping"), "ping")
        wait(for: [wire.done], timeout: 2)
        close(wire.client); close(wire.server)
    }

    func testAnEarlyAnswerAndAServerThatSaysNothing() throws {
        // "100 Continue" goes through as it is; the real head after it is the one that is closed.
        let wire = try exchange("POST /up HTTP/1.1\r\nHost: storefront.localhost\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n")
        _ = read(wire.server, until: "\r\n\r\n")
        send(wire.server, "HTTP/1.1 100 Continue\r\n\r\n")
        XCTAssertEqual(read(wire.client, until: "\r\n\r\n"), "HTTP/1.1 100 Continue\r\n\r\n")
        send(wire.client, "abc")
        XCTAssertEqual(read(wire.server, until: "abc"), "abc")
        send(wire.server, "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(read(wire.client, until: "\r\n\r\n").contains("\r\nConnection: close\r\n"))
        close(wire.server)
        wait(for: [wire.done], timeout: 5)
        close(wire.client)

        // A server that closes without a word: the browser is told, not left hanging.
        let mute = try exchange("GET / HTTP/1.1\r\nHost: storefront.localhost\r\n\r\n")
        _ = read(mute.server, until: "\r\n\r\n")
        close(mute.server)
        XCTAssertTrue(read(mute.client).hasPrefix("HTTP/1.1 502 Bad Gateway\r\n"))
        wait(for: [mute.done], timeout: 5)
        close(mute.client)
    }

    // MARK: Where it may connect

    func testOnlyThisMacsOwnAddresses() {
        XCTAssertTrue(Sock.isOwn("127.0.0.1"))
        XCTAssertTrue(Sock.isOwn("::1"))
        // Addresses that aren't on any of this Mac's interfaces (documentation ranges): never.
        for address in ["203.0.113.9", "198.51.100.7", "192.0.2.1", "2001:db8::1", "8.8.8.8", "not an address", ""] {
            XCTAssertFalse(Sock.isOwn(address), address)
        }
        if let lan = LAN.ipv4() { XCTAssertTrue(Sock.isOwn(lan), lan) }           // the one it does have, when on a network
        XCTAssertEqual(["127.0.0.1", "203.0.113.9", "::1"].filter(Sock.isOwn), ["127.0.0.1", "::1"])
    }

    func testHalfAPairFromLaunchdIsNoPair() {
        XCTAssertTrue(Sock.allBound([8490, 8490]))
        XCTAssertFalse(Sock.allBound([8490, 0]))                                   // another program has the other address
        XCTAssertFalse(Sock.allBound([0, 8470]))
        XCTAssertFalse(Sock.allBound([]))
    }
}
