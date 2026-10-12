import CryptoKit
import JavaScriptCore
import XCTest
@testable import Harbor

/// On network: who gets to a shared project and who doesn't. The gate, the password
/// challenge, the wrong-try limits, and what the network listener answers to, as pure
/// functions with the clock passed in; then the listener itself, through this Mac's own
/// network address. Nothing here touches the Keychain.
final class OnNetworkTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: The gate

    func testGateDecisions() {
        func step(_ method: String, _ target: String, protected: Bool = true, session: Bool = false) -> Gate.Step {
            Gate.step(method: method, target: target, protected: protected, session: session)
        }
        // A password, and no session: harbor's sign-in page, whatever is asked for.
        for (method, target) in [("GET", "/"), ("GET", "/admin?x=1"), ("POST", "/api/save"), ("DELETE", "/x"), ("GET", "/hmr")] {
            XCTAssertEqual(step(method, target), .signIn, "\(method) \(target)")
        }
        // With a session: on to the project.
        XCTAssertEqual(step("GET", "/", session: true), .forward)
        XCTAssertEqual(step("POST", "/api/save", session: true), .forward)
        // No password: everything goes on.
        XCTAssertEqual(step("GET", "/", protected: false), .forward)
        // Harbor's own paths are harbor's: never the project's, with or without a session.
        XCTAssertEqual(step("POST", "/__harbor/challenge"), .challenge)
        XCTAssertEqual(step("POST", "/__harbor/enter"), .enter)
        XCTAssertEqual(step("POST", "/__harbor/enter?x=1", session: true), .enter)
        for (method, target) in [("GET", "/__harbor/enter"), ("GET", "/__harbor/"), ("GET", "/__harbor"), ("POST", "/__harbor/other"), ("PUT", "/__harbor/challenge")] {
            XCTAssertEqual(step(method, target), .notFound, "\(method) \(target)")
            XCTAssertEqual(step(method, target, session: true), .notFound, "\(method) \(target) with a session")
        }
        XCTAssertEqual(step("POST", "/__harbor/enter", protected: false), .notFound)      // no password, no sign-in; still not the project's
        XCTAssertEqual(step("GET", "/__harbor/x", protected: false, session: true), .notFound)
        // A path that only looks like it belongs to the project.
        XCTAssertEqual(step("GET", "/__harborx/enter", session: true), .forward)
        XCTAssertEqual(step("GET", "/app/__harbor/enter", session: true), .forward)
    }

    func testAWebSocketIsARequestLikeAnyOther() throws {
        // The gate looks at the method and the path; an upgrade without a session gets the page, not the project.
        let upgrade = try XCTUnwrap(ProxyHead(Data("GET /hmr HTTP/1.1\r\nHost: storefront.local\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n".utf8)))
        XCTAssertTrue(upgrade.isWebSocket)
        XCTAssertEqual(Gate.step(method: upgrade.method, target: upgrade.target, protected: true, session: false), .signIn)
        XCTAssertEqual(Gate.step(method: upgrade.method, target: upgrade.target, protected: true, session: true), .forward)
    }

    func testSessions() {
        var visitors = Visitors()
        let token = visitors.signIn(to: "storefront", now: t0)
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", now: t0.addingTimeInterval(11 * 3600)))
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", now: t0.addingTimeInterval(12 * 3600 + 1)))   // twelve hours
        XCTAssertFalse(visitors.isSignedIn(token, to: "notes", now: t0))                                           // for that name only
        XCTAssertFalse(visitors.isSignedIn(nil, to: "storefront", now: t0))
        XCTAssertFalse(visitors.isSignedIn("", to: "storefront", now: t0))
        XCTAssertFalse(visitors.isSignedIn(token + "x", to: "storefront", now: t0))
        XCTAssertFalse(visitors.isSignedIn(String(token.dropLast()), to: "storefront", now: t0))
        // Sharing stops, or the password changes: everyone signs in again.
        visitors.forget("storefront")
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", now: t0))
        XCTAssertEqual(token.count, 48)
        XCTAssertNotEqual(token, visitors.signIn(to: "storefront", now: t0))
    }

    // MARK: The challenge

    private func answer(_ password: String, salt: String, name: String, nonce: String) -> String {
        Lan.proof(key: Lan.key(password: password, salt: salt), name: name, nonce: nonce)
    }

    func testChallengeVerify() {
        let salt = "5f1d9c7a02a81e3b", secret = Lan.key(password: "k7mqx2hw", salt: salt)
        var visitors = Visitors()
        func enter(_ proof: String?, _ nonce: String, name: String = "storefront", from address: String = "192.168.1.30", at now: Date? = nil) -> OnNetwork.Entry {
            OnNetwork.check(proof: proof, nonce: nonce, name: name, secret: secret, address: address, visitors: &visitors, now: now ?? t0)
        }
        func right(_ nonce: String, for name: String = "storefront") -> String { answer("k7mqx2hw", salt: salt, name: name, nonce: nonce) }
        let wrong = OnNetwork.Entry.wrong(wait: nil, many: false)

        // The right password: a session.
        var nonce = visitors.challenge(for: "storefront", now: t0)
        guard case .signedIn(let token) = enter(right(nonce), nonce) else { return XCTFail("the right answer signs in") }
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", now: t0))
        // The same answer again, by whoever overheard it: the challenge has let someone in already.
        XCTAssertEqual(enter(right(nonce), nonce, from: "192.168.1.66"), .again)
        // A wrong password is a wrong try. The challenge is still good for the right one.
        nonce = visitors.challenge(for: "storefront", now: t0)
        XCTAssertEqual(enter(answer("k7mqx2hx", salt: salt, name: "storefront", nonce: nonce), nonce), wrong)
        guard case .signedIn = enter(right(nonce), nonce) else { return XCTFail("a wrong try doesn't use the challenge up") }
        // No proof at all, or the password itself as the proof: wrong tries.
        nonce = visitors.challenge(for: "storefront", now: t0)
        XCTAssertEqual(enter(nil, nonce, from: "192.168.1.34"), wrong)
        XCTAssertEqual(enter("k7mqx2hw", nonce, from: "192.168.1.35"), wrong)
        // The proof is bound to the name: the right password's answer for another name is wrong here.
        XCTAssertEqual(enter(right(nonce, for: "notes"), nonce, from: "192.168.1.36"), wrong)

        // A challenge that isn't good is never a wrong try, whatever comes with it: start again.
        let phone = "192.168.1.40"
        nonce = visitors.challenge(for: "storefront", now: t0)
        XCTAssertEqual(enter(right(nonce), nonce, from: phone, at: t0.addingTimeInterval(121)), .again)        // older than two minutes
        XCTAssertNotEqual(enter(right(nonce), nonce, from: "192.168.1.41", at: t0.addingTimeInterval(119)), .again)
        let forNotes = visitors.challenge(for: "notes", now: t0)
        XCTAssertEqual(enter(right(forNotes), forNotes, from: phone), .again)                                 // made for another name
        let later = nonce.replacingOccurrences(of: nonce.prefix { $0 != "." }, with: "\(Int(t0.timeIntervalSince1970) + 9999)")
        XCTAssertEqual(enter(right(later), later, from: phone), .again)                                       // its end moved out
        let other = Visitors().challenge(for: "storefront", now: t0)
        XCTAssertEqual(enter(right(other), other, from: phone), .again)                                       // from another launch of harbor
        for made in ["", "0011", "..", "1.2.3", String(nonce.dropLast()), nonce + "0", nonce.uppercased(), String(repeating: "9", count: 400)] {
            XCTAssertEqual(enter(right(made), made, from: phone), .again, made)
            XCTAssertEqual(enter("not-a-proof", made, from: phone), .again, made)
        }
        // None of those counted against the phone: four wrong tries later it still isn't locked.
        for _ in 0..<4 {
            nonce = visitors.challenge(for: "storefront", now: t0)
            XCTAssertEqual(enter("wrong", nonce, from: phone), wrong)
        }
        XCTAssertNil(visitors.wait(address: phone, name: "storefront", now: t0))
    }

    func testAFloodOfChallengesIsInNobodysWay() {
        let salt = "5f1d9c7a02a81e3b", secret = Lan.key(password: "k7mqx2hw", salt: salt), phone = "192.168.1.30"
        var visitors = Visitors()
        // The visitor's page has fetched its challenge and is still working out the answer.
        let nonce = visitors.challenge(for: "storefront", now: t0)
        // Meanwhile someone asks for ten thousand, and posts junk answers to a thousand made-up ones, from the visitor's own address too.
        for _ in 0..<10_000 { _ = visitors.challenge(for: "storefront", now: t0.addingTimeInterval(1)) }
        XCTAssertEqual(visitors.counts.used, 0)                                           // nothing was kept for any of them
        for i in 0..<1000 {
            let junk = "\(Int(t0.timeIntervalSince1970) + 100).\(Lan.token(16)).\(Lan.token(32))"
            XCTAssertEqual(OnNetwork.check(proof: "junk", nonce: junk, name: "storefront", secret: secret, address: i % 2 == 0 ? phone : "192.168.1.66",
                                           visitors: &visitors, now: t0.addingTimeInterval(1)), .again)
        }
        XCTAssertEqual(visitors.counts.addresses, 0)                                      // and nobody was charged a wrong try
        // The visitor's answer arrives: in.
        guard case .signedIn = OnNetwork.check(proof: answer("k7mqx2hw", salt: salt, name: "storefront", nonce: nonce), nonce: nonce, name: "storefront",
                                               secret: secret, address: phone, visitors: &visitors, now: t0.addingTimeInterval(2)) else {
            return XCTFail("the right password signs in, flood or no flood")
        }
    }

    func testALockedAddressIsNotHeard() {
        let salt = "5f1d9c7a02a81e3b", secret = Lan.key(password: "k7mqx2hw", salt: salt), phone = "192.168.1.30"
        var visitors = Visitors()
        func enter(_ password: String, nonce given: String? = nil, from address: String = phone, at now: Date) -> OnNetwork.Entry {
            let nonce = given ?? visitors.challenge(for: "storefront", now: now)
            return OnNetwork.check(proof: answer(password, salt: salt, name: "storefront", nonce: nonce), nonce: nonce, name: "storefront",
                                   secret: secret, address: address, visitors: &visitors, now: now)
        }
        // Four wrong, then the right one: in, and the count starts again from nothing.
        for _ in 0..<4 { XCTAssertEqual(enter("wrong-pass", at: t0), .wrong(wait: nil, many: false)) }
        guard case .signedIn = enter("k7mqx2hw", at: t0) else { return XCTFail("the fifth try, right, signs in") }
        for _ in 0..<4 { XCTAssertEqual(enter("wrong-pass", at: t0), .wrong(wait: nil, many: false)) }
        // A challenge fetched before the lock is no way round it.
        let early = visitors.challenge(for: "storefront", now: t0)
        XCTAssertEqual(enter("wrong-pass", at: t0), .wrong(wait: 300, many: false))                  // the fifth wrong in a row: five minutes
        XCTAssertEqual(enter("k7mqx2hw", nonce: early, at: t0.addingTimeInterval(10)), .locked(wait: 290))
        XCTAssertEqual(enter("k7mqx2hw", at: t0.addingTimeInterval(299)), .locked(wait: 1))
        // Somebody else is heard meanwhile, and so is this address once the wait is over.
        guard case .signedIn = enter("k7mqx2hw", from: "192.168.1.31", at: t0.addingTimeInterval(10)) else { return XCTFail("another address isn't locked") }
        guard case .signedIn = enter("k7mqx2hw", at: t0.addingTimeInterval(300)) else { return XCTFail("after the wait the right password works") }
    }

    func testThePagesArithmeticMatchesTheApps() throws {
        // The sign-in page computes the answer in plain JavaScript; the app with CommonCrypto and CryptoKit.
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(SignIn.crypto)
        XCTAssertNil(js.exception)
        func run(_ script: String) -> String { js.evaluateScript(script)?.toString() ?? "" }
        // Known answers: SHA-256, HMAC-SHA256 (RFC 4231), PBKDF2-HMAC-SHA256.
        XCTAssertEqual(run("hex(sha256(utf8('abc')))"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(run("hex(sha256(utf8('')))"), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(run("hex(sha256(utf8('\(String(repeating: "a", count: 200))')))"), SHA256.hash(data: Data(String(repeating: "a", count: 200).utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(run("hex(hmac(utf8('Jefe'), utf8('what do ya want for nothing?')))"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(run("hex(pbkdf2(utf8('password'), utf8('salt'), 1))"), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(run("hex(pbkdf2(utf8('password'), utf8('salt'), 2))"), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(run("hex(pbkdf2(utf8('password'), utf8('salt'), 4096))"), "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(Lan.key(password: "password", salt: "salt", iterations: 4096).map { String(format: "%02x", $0) }.joined(),
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        // The whole answer, at the real round count, for ordinary, long and non-ASCII passwords.
        for password in ["k7mqx2hw", "correct horse battery staple", String(repeating: "long-password-", count: 8), "pässwörd ✓ 密码", "12345678"] {
            let salt = Lan.token(16), nonce = Lan.token(16)
            let literal = String(data: try JSONSerialization.data(withJSONObject: [password]), encoding: .utf8)!
            XCTAssertEqual(run("harborProof(\(literal)[0], '\(salt)', 'storefront', '\(nonce)', \(Lan.iterations))"),
                           answer(password, salt: salt, name: "storefront", nonce: nonce), password)
        }
        XCTAssertNil(js.exception)
    }

    // MARK: Wrong tries

    func testWrongTriesPerAddress() {
        var visitors = Visitors()
        let phone = "192.168.1.30"
        for _ in 0..<4 { XCTAssertFalse(visitors.wrong(address: phone, name: "storefront", now: t0)) }
        XCTAssertNil(visitors.wait(address: phone, name: "storefront", now: t0))                // four wrong: still allowed
        _ = visitors.wrong(address: phone, name: "storefront", now: t0)
        XCTAssertEqual(visitors.wait(address: phone, name: "storefront", now: t0), 300)          // the fifth: five minutes
        XCTAssertNil(visitors.wait(address: "192.168.1.31", name: "storefront", now: t0))        // somebody else isn't locked
        XCTAssertNil(visitors.wait(address: phone, name: "notes", now: t0))                      // nor this address for another name
        XCTAssertEqual(visitors.wait(address: phone, name: "storefront", now: t0.addingTimeInterval(299)), 1)
        XCTAssertNil(visitors.wait(address: phone, name: "storefront", now: t0.addingTimeInterval(300)))
        // Each lock is twice the one before, up to an hour.
        var now = t0.addingTimeInterval(300)
        for expected in [600, 1200, 2400, 3600, 3600] {
            for _ in 0..<5 { _ = visitors.wrong(address: phone, name: "storefront", now: now) }
            XCTAssertEqual(visitors.wait(address: phone, name: "storefront", now: now), expected)
            now = now.addingTimeInterval(Double(expected))
        }
        // The right password clears the count.
        var other = Visitors()
        for _ in 0..<4 { _ = other.wrong(address: phone, name: "storefront", now: t0) }
        other.right(address: phone, name: "storefront")
        for _ in 0..<4 { _ = other.wrong(address: phone, name: "storefront", now: t0) }
        XCTAssertNil(other.wait(address: phone, name: "storefront", now: t0))
    }

    func testManyWrongTriesSlowTheNameAndLockNobodyOut() {
        let salt = "5f1d9c7a02a81e3b", secret = Lan.key(password: "k7mqx2hw", salt: salt)
        var visitors = Visitors()
        // Thirty wrong tries in ten minutes from many addresses: nothing yet.
        for i in 0..<30 { XCTAssertFalse(visitors.wrong(address: "192.168.1.\(i + 2)", name: "storefront", now: t0.addingTimeInterval(Double(i)))) }
        XCTAssertEqual(visitors.delay(for: "storefront", now: t0.addingTimeInterval(30)), 0)
        // One more: the owner is told (true), and for ten minutes every answer for the name takes two seconds longer.
        let at = t0.addingTimeInterval(31)
        XCTAssertTrue(visitors.wrong(address: "192.168.1.100", name: "storefront", now: at))
        XCTAssertEqual(visitors.delay(for: "storefront", now: at), 2)
        XCTAssertEqual(visitors.delay(for: "notes", now: at), 0)                           // another name isn't slowed
        XCTAssertEqual(visitors.delay(for: "storefront", now: at.addingTimeInterval(599)), 2)
        XCTAssertEqual(visitors.delay(for: "storefront", now: at.addingTimeInterval(600)), 0)
        // Nobody is locked out by other people's tries: a visitor from a new address signs in.
        XCTAssertNil(visitors.wait(address: "192.168.1.200", name: "storefront", now: at))
        let nonce = visitors.challenge(for: "storefront", now: at)
        guard case .signedIn = OnNetwork.check(proof: answer("k7mqx2hw", salt: salt, name: "storefront", nonce: nonce), nonce: nonce, name: "storefront",
                                               secret: secret, address: "192.168.1.200", visitors: &visitors, now: at) else {
            return XCTFail("the right password still signs in while someone else is guessing")
        }
        // The guessing goes on: the owner isn't told again while the name is already slowed, and it stays slowed.
        for i in 0..<40 { XCTAssertFalse(visitors.wrong(address: "192.168.3.\(i + 2)", name: "storefront", now: at.addingTimeInterval(Double(i + 1)))) }
        XCTAssertEqual(visitors.delay(for: "storefront", now: at.addingTimeInterval(620)), 2)
        // Spread over more than ten minutes, thirty-one wrong tries slow nothing.
        var slow = Visitors()
        for i in 0..<40 { XCTAssertFalse(slow.wrong(address: "192.168.1.\(i + 2)", name: "storefront", now: t0.addingTimeInterval(Double(i) * 25))) }
        XCTAssertEqual(slow.delay(for: "storefront", now: t0.addingTimeInterval(1000)), 0)
    }

    func testACrowdOfAddressesGainsNothing() {
        var visitors = Visitors()
        func lock(_ address: String, at now: Date) { for _ in 0..<5 { _ = visitors.wrong(address: address, name: "storefront", now: now) } }
        func address(_ i: Int) -> String { "10.0.\(i / 256).\(i % 256)" }
        // As many addresses as the table has room for, each locked after its five tries.
        for i in 0..<Visitors.maxAddresses { lock(address(i), at: t0) }
        XCTAssertEqual(visitors.counts.addresses, Visitors.maxAddresses)
        // One more address: it waits for the first of them, and none is pushed out to try again early.
        XCTAssertEqual(visitors.wait(address: "10.9.9.9", name: "storefront", now: t0.addingTimeInterval(1)), 299)
        XCTAssertEqual(visitors.wait(address: address(0), name: "storefront", now: t0.addingTimeInterval(1)), 299)
        XCTAssertFalse(visitors.wrong(address: "10.9.9.9", name: "storefront", now: t0.addingTimeInterval(1)))
        XCTAssertEqual(visitors.counts.addresses, Visitors.maxAddresses)
        // Every one of them is still in the book with its lock behind it: its next one is the second, ten minutes.
        var later = t0.addingTimeInterval(300)
        for i in 0..<Visitors.maxAddresses { lock(address(i), at: later) }
        XCTAssertTrue((0..<Visitors.maxAddresses).allSatisfy { visitors.wait(address: address($0), name: "storefront", now: later) == 600 })
        XCTAssertEqual(visitors.wait(address: "10.9.9.9", name: "storefront", now: later), 600)
        // When their wait is over a newcomer is let in, but with the table still full its first lock is the long one.
        later = later.addingTimeInterval(600)
        XCTAssertNil(visitors.wait(address: "10.9.9.9", name: "storefront", now: later))
        lock("10.9.9.9", at: later)
        XCTAssertEqual(visitors.wait(address: "10.9.9.9", name: "storefront", now: later), 3600)
        XCTAssertEqual(visitors.counts.addresses, Visitors.maxAddresses)
        // With room in the table, a first lock is five minutes.
        var quiet = Visitors()
        for _ in 0..<5 { _ = quiet.wrong(address: "10.9.9.9", name: "storefront", now: t0) }
        XCTAssertEqual(quiet.wait(address: "10.9.9.9", name: "storefront", now: t0), 300)
    }

    func testNothingAVisitorDoesGrowsWithoutBound() {
        var visitors = Visitors()
        for i in 0..<5000 {
            _ = visitors.challenge(for: "storefront", now: t0)
            _ = visitors.signIn(to: "storefront", now: t0)
            _ = visitors.wrong(address: "10.\(i / 65536).\(i / 256 % 256).\(i % 256)", name: "name-\(i % 3)", now: t0.addingTimeInterval(Double(i) / 100))
        }
        let counts = visitors.counts
        XCTAssertEqual(counts.used, 0)                                                    // a challenge that was only asked for costs nothing
        XCTAssertLessThanOrEqual(counts.sessions, Visitors.maxSessions)
        XCTAssertLessThanOrEqual(counts.addresses, Visitors.maxAddresses)
        XCTAssertLessThanOrEqual(counts.recent, 3 * (Visitors.manyTries + 1))
        // Challenges that let someone in are remembered until they would end anyway, and only so many at once.
        let salt = "5f1d9c7a02a81e3b", secret = Lan.key(password: "k7mqx2hw", salt: salt)
        var busy = Visitors(), entered = 0
        func signIn(at now: Date) -> OnNetwork.Entry {
            let nonce = busy.challenge(for: "storefront", now: now)
            return OnNetwork.check(proof: Lan.proof(key: secret, name: "storefront", nonce: nonce), nonce: nonce, name: "storefront", secret: secret,
                                   address: "192.168.1.30", visitors: &busy, now: now)
        }
        for _ in 0..<(Visitors.maxUsed + 50) { if case .signedIn = signIn(at: t0) { entered += 1 } }
        XCTAssertEqual(entered, Visitors.maxUsed)
        XCTAssertEqual(busy.counts.used, Visitors.maxUsed)
        XCTAssertEqual(signIn(at: t0), .again)                                            // no room to remember one more: nobody gets in on it
        guard case .signedIn = signIn(at: t0.addingTimeInterval(121)) else { return XCTFail("room again once the old ones have ended") }
        XCTAssertEqual(busy.counts.used, 1)
    }

    // MARK: What the project never sees

    func testHarborsCookieIsTakenOut() throws {
        XCTAssertEqual(Lan.strip("a=1; __harbor_visitor=abc123; theme=dark"), "a=1; theme=dark")
        XCTAssertEqual(Lan.strip("__harbor_visitor=abc123; a=1"), "a=1")
        XCTAssertEqual(Lan.strip("a=1;__harbor_visitor=abc123"), "a=1")
        XCTAssertNil(Lan.strip("__harbor_visitor=abc123"))                           // nothing else: no Cookie header at all
        XCTAssertNil(Lan.strip(" __harbor_visitor=abc123 ; "))
        XCTAssertEqual(Lan.strip("my__harbor_visitor=1; x__harbor_visitor=2"), "my__harbor_visitor=1; x__harbor_visitor=2")   // not harbor's
        XCTAssertEqual(Lan.visitor(in: ["a=1; __harbor_visitor=abc123; b=2"]), "abc123")
        XCTAssertEqual(Lan.visitor(in: ["a=1", "__harbor_visitor=tok"]), "tok")
        XCTAssertNil(Lan.visitor(in: ["a=1; my__harbor_visitor=abc"]))
        XCTAssertNil(Lan.visitor(in: []))
        // In the head the project gets: its own cookies stay, harbor's is gone.
        let request = try XCTUnwrap(ProxyHead(Data("GET / HTTP/1.1\r\nHost: storefront.local\r\nCookie: sid=9; __harbor_visitor=secret-token\r\nCookie: __harbor_visitor=second\r\n\r\n".utf8)))
        let sent = String(decoding: request.forwarded(client: "192.168.1.30", dropCookie: true), as: UTF8.self)
        XCTAssertTrue(sent.contains("\r\nCookie: sid=9\r\n"), sent)
        XCTAssertFalse(sent.contains("__harbor_visitor"))
        XCTAssertFalse(sent.contains("secret-token") || sent.contains("second"))
        XCTAssertTrue(sent.contains("\r\nHost: storefront.local\r\n"))
        XCTAssertTrue(sent.contains("\r\nX-Forwarded-For: 192.168.1.30\r\n"))
    }

    // MARK: What the listener answers to

    func testOnlyTheAnnouncedAddressIsAnswered() {
        XCTAssertTrue(Lan.accepts(local: "192.168.1.24", announced: "192.168.1.24"))
        // The listener hears every interface; everything that didn't arrive on the announced address is dropped.
        for local in ["127.0.0.1", "10.8.0.2", "192.168.1.25", "172.16.0.1", "::1", ""] {
            XCTAssertFalse(Lan.accepts(local: local, announced: "192.168.1.24"), local)
        }
        XCTAssertFalse(Lan.accepts(local: "192.168.1.24", announced: nil))               // nothing announced: nothing answered
    }

    func testHostRoutingOnTheNetwork() {
        let shared: Set = ["storefront", "notes-api"]
        func name(_ host: String, port: UInt16 = 80) -> String? { Lan.name(forHost: host, port: port, isShared: shared.contains) }
        XCTAssertEqual(name("storefront.local"), "storefront")
        XCTAssertEqual(name("Storefront.LOCAL"), "storefront")
        XCTAssertEqual(name("notes-api.local"), "notes-api")
        // Not shared, a .localhost name, harbor's own page, addresses, look-alikes: nobody's.
        for host in ["blog.local", "storefront.localhost", "harbor.localhost:8470", "harbor.localhost", "harbor.local", "192.168.1.24", "192.168.1.24:80",
                     "127.0.0.1", "[::1]", "localhost", "storefront", "storefront.local.evil.com", "evil.com", "storefront.local:8491", "storefront.local:80",
                     "storefront.local.", "x.storefront.local", "storefrontxlocal", ".local", ""] {
            XCTAssertNil(name(host), host)
        }
        // On the high port the Host carries it, and only that one.
        XCTAssertEqual(name("storefront.local:8491", port: 8491), "storefront")
        for host in ["storefront.local", "storefront.local:80", "storefront.local:8492", "storefront.localhost:8491", "192.168.1.24:8491", "blog.local:8491"] {
            XCTAssertNil(name(host, port: 8491), host)
        }
    }

    // MARK: Another network

    func testAnotherNetworkIsNoticed() {
        func net(_ address: String = "192.168.1.24", router: String = "192.168.1.1", hardware: String? = "a4:91:b1:00:00:01", on interface: String = "en0") -> LAN.Network {
            LAN.Network(interface: interface, address: address, router: router, routerHardware: hardware)
        }
        let home = net()
        XCTAssertEqual(Lan.change(from: home, to: home), .same)
        XCTAssertEqual(Lan.change(from: home, to: nil), .same)                           // no network for a moment isn't another one yet
        XCTAssertEqual(Lan.change(from: nil, to: home), .same)
        XCTAssertEqual(Lan.change(from: home, to: net("10.0.0.7", router: "10.0.0.1", hardware: "f0:9f:c2:00:00:09")), .left)       // the café
        XCTAssertEqual(Lan.change(from: home, to: net(router: "192.168.1.254")), .left)
        XCTAssertEqual(Lan.change(from: home, to: net(on: "en7")), .left)
        // A café whose router has the same address as mine, and even gives me the same one: its hardware is not mine.
        XCTAssertEqual(Lan.change(from: home, to: net(hardware: "f0:9f:c2:00:00:09")), .left)
        XCTAssertEqual(Lan.change(from: home, to: net("192.168.1.77", hardware: "f0:9f:c2:00:00:09")), .left)
        // My own router hands me another address: the same network, and the name moves with me.
        XCTAssertEqual(Lan.change(from: home, to: net("192.168.1.77")), .moved)
        // A new address from a router macOS can't vouch for (yet) is not taken for the same network.
        XCTAssertEqual(Lan.change(from: home, to: net("192.168.1.77", hardware: nil)), .left)
        XCTAssertEqual(Lan.change(from: net(hardware: nil), to: net("192.168.1.77")), .left)
        XCTAssertEqual(Lan.change(from: net(hardware: nil), to: home), .same)            // the same address, the router just got known
    }

    @MainActor
    func testJoiningAnotherNetworkTurnsSharingOff() {
        _ = DebugCLI.handle(["--no-open", "--fixture", "shared"])
        _ = DebugCLI.afterLaunch()                                                       // applies the made-up ports
        let m = Monitor.shared
        XCTAssertEqual(m.lanShares.count, 1)
        XCTAssertEqual(m.portNotes.first, "1 project on your network")
        // What the page is told about it: its name there, that it is on, its link, and that it has a password. Never the password.
        var state: [String: Any] = [:]
        WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
        let rows = (state["ports"] as? [[String: Any]]) ?? []
        let shared = rows.first { ($0["port"] as? Int) == 3000 }?["local"] as? [String: Any]
        XCTAssertEqual(shared?["on"] as? Bool, true)
        XCTAssertEqual(shared?["link"] as? String, "http://\(m.lanShares.values.first?.name ?? "").local/")
        XCTAssertEqual(shared?["password"] as? Bool, true)
        XCTAssertEqual(Set((shared ?? [:]).keys), ["name", "on", "link", "password", "trouble"])
        XCTAssertTrue(shared?["trouble"] is NSNull)                                       // announced: nothing to say
        XCTAssertTrue(rows.first { ($0["port"] as? Int) == 3001 }?["local"] is NSNull)       // only the project's main server carries it
        XCTAssertTrue(rows.first { ($0["port"] as? Int) == 5432 }?["local"] is NSNull)       // a database has no name at all
        var home = LAN.Network(interface: "en0", address: "192.168.1.24", router: "192.168.1.1")
        m.checkNetwork(now: home)
        m.checkNetwork(now: nil)
        home.routerHardware = "a4:91:b1:00:00:01"
        m.checkNetwork(now: home)                                                        // macOS got to know the router
        m.checkNetwork(now: LAN.Network(interface: "en0", address: "192.168.1.77", router: "192.168.1.1", routerHardware: "a4:91:b1:00:00:01"))
        XCTAssertEqual(m.lanShares.count, 1)                                             // the same network, none for a moment, a new address on it: still on
        let notices = m.notices.last?.id
        // The same router address and even the same address for this Mac, but another router: another network.
        m.checkNetwork(now: LAN.Network(interface: "en0", address: "192.168.1.77", router: "192.168.1.1", routerHardware: "f0:9f:c2:00:00:09"))
        XCTAssertTrue(m.lanShares.isEmpty)                                               // another network: off, and said so
        XCTAssertNotEqual(m.notices.last?.id, notices)                                 // a new notice (only the last five are kept)
        XCTAssertTrue(m.notices.last?.text.contains("different network") == true)
        XCTAssertTrue(m.portNotes.allSatisfy { !$0.contains("on your network") })
    }

    /// The made-up Mac with the storefront on the network, and that project's rows.
    @MainActor
    private func sharedFixture() -> (monitor: Monitor, name: String, rows: [PortRow]) {
        _ = DebugCLI.handle(["--no-open", "--fixture", "shared"])
        _ = DebugCLI.afterLaunch()
        let m = Monitor.shared
        XCTAssertEqual(m.lanShares.count, 1)
        return (m, m.lanShares.values.first?.name ?? "", m.ports)
    }

    /// The same row as another process: started again under a new pid, or (the same pid given out again) just started later.
    private func restarted(_ r: PortRow, pid: pid_t? = nil) -> PortRow {
        PortRow(port: r.port, addresses: r.addresses, scope: r.scope, pid: pid ?? r.pid, ppid: r.ppid, processName: r.processName, path: r.path, cwd: r.cwd,
                projectRoot: r.projectRoot, command: r.command, started: Date(), footprint: r.footprint, workers: r.workers, workerPids: r.workerPids,
                isSystem: r.isSystem, appBundle: r.appBundle, appName: r.appName, framework: r.framework, category: r.category, isSelf: r.isSelf)
    }

    @MainActor
    func testAProjectThatStopsComesOffTheNetwork() {
        let (m, name, rows) = sharedFixture()
        // Its second server stops: the one it is shared for still runs, so it is still shared.
        m.useFixture(rows.filter { $0.port != 3001 }, shared: nil)
        XCTAssertEqual(m.lanShares.count, 1)
        // That one stops too: off the network, and said so.
        let notices = m.notices.last?.id
        m.useFixture(rows.filter { $0.port != 3000 && $0.port != 3001 }, shared: nil)
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertNotEqual(m.notices.last?.id, notices)                                 // a new notice (only the last five are kept)
        XCTAssertEqual(m.notices.last?.text, "\(name).local stopped, so it is off the network.")
    }

    @MainActor
    func testASharedNameNeverMovesToAnotherServer() {
        // The server it is shared for stops while another of the project's servers runs on. The
        // project's name moves to that one; the sharing does not.
        var (m, name, rows) = sharedFixture()
        var notices = m.notices.last?.id
        m.useFixture(rows.filter { $0.port != 3000 }, shared: nil)
        XCTAssertNotNil(m.names.targets["storefront"], "the project still has a server, and its .localhost name")
        XCTAssertEqual(m.names.targets["storefront"]?.port, 3001)
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertNotEqual(m.notices.last?.id, notices)                                 // a new notice (only the last five are kept)
        XCTAssertEqual(m.notices.last?.text, "\(name).local stopped, so it is off the network.")
        // The same port, but another process: the server was started again, or something else took
        // the port. Under a new pid, or under the old one given out again.
        for pid in [9000, nil] as [pid_t?] {
            (m, name, rows) = sharedFixture()
            notices = m.notices.last?.id
            m.useFixture(rows.map { $0.port == 3000 ? restarted($0, pid: pid) : $0 }, shared: nil)
            XCTAssertEqual(m.names.targets["storefront"]?.port, 3000)
            XCTAssertTrue(m.lanShares.isEmpty, "pid \(pid.map(String.init) ?? "the same")")
            XCTAssertNotEqual(m.notices.last?.id, notices)                                 // a new notice (only the last five are kept)
        }
        // Another program starts listening on the server's port too (on one address, in front of a
        // server that listens on all of them): a request could land on it, so the sharing stops.
        (m, name, rows) = sharedFixture()
        notices = m.notices.last?.id
        let server = rows.first { $0.port == 3000 }!
        // The server's own worker on that port is not "another program".
        let worker = PortRow(port: 3000, addresses: ["127.0.0.1"], scope: .loopback, pid: 4777, ppid: server.pid, processName: "node", path: nil, cwd: nil,
                             projectRoot: nil, command: nil, started: Date(), footprint: nil, workers: 0, workerPids: [], isSystem: false, appBundle: nil,
                             appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertNil(Monitor.otherListener(on: 3000, than: server.pid, in: rows + [worker]))
        m.useFixture(rows + [worker], shared: nil)
        XCTAssertEqual(m.lanShares.count, 1)
        let intruder = PortRow(port: 3000, addresses: ["127.0.0.1"], scope: .loopback, pid: 4888, ppid: 1, processName: "python3", path: nil, cwd: nil,
                               projectRoot: nil, command: nil, started: Date(), footprint: nil, workers: 0, workerPids: [], isSystem: false, appBundle: nil,
                               appName: nil, framework: nil, category: .dev, isSelf: false)
        XCTAssertEqual(Monitor.otherListener(on: 3000, than: server.pid, in: rows + [intruder])?.pid, 4888)
        XCTAssertNil(Monitor.otherListener(on: 3001, than: 4102, in: rows + [intruder]))
        m.useFixture(rows + [intruder], shared: nil)
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertNotEqual(m.notices.last?.id, notices)                                 // a new notice (only the last five are kept)
        XCTAssertEqual(m.notices.last?.text, "python3 is listening on port 3000 too, so \(name).local is off the network.")
        // And with it there the project can't be put on the network in the first place.
        XCTAssertEqual(m.shareOnNetwork(server, open: true), "python3 is listening on port 3000 too, so \(name).local can't go on the network.")
        m.useFixture(rows, shared: nil)
        // And only the row its name goes to can be put on the network at all.
        (m, name, rows) = sharedFixture()
        let second = rows.first { $0.port == 3001 }!
        XCTAssertEqual(m.shareOnNetwork(second, open: true), "Only the server storefront.localhost opens can go on the network.")
        XCTAssertEqual(m.lanShares.count, 1)
        m.stopAllSharing()
        // One process on both ports, listed the other way round: the page's "turn on" names the process, and means the name's row.
        m.useFixture([restarted(second, pid: 4101)] + rows.filter { $0.port != 3001 }, shared: nil)
        XCTAssertEqual(m.ports.first { $0.pid == 4101 }?.port, 3001)
        XCTAssertEqual(m.networkRow(forPid: 4101)?.port, 3000)
        XCTAssertNil(m.networkRow(forPid: 612))                                          // a database has no name, so no such row
        m.useFixture(rows, shared: nil)
        // Nor a row whose process isn't there (any more): the made-up Mac's servers don't exist on this one.
        let main = rows.first { $0.port == 3000 }!
        XCTAssertEqual(m.shareOnNetwork(main, open: true), "storefront on port 3000 isn't running any more.")
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertEqual(OnNetwork.shared.port, 0)
    }

    // MARK: Names and passwords

    func testNetworkNameValidation() {
        let others: Set = ["notes-api", "blog"]
        func problem(_ name: String) -> String? { Lan.nameProblem(name, others: others, machine: "Sams-MacBook.local") }
        XCTAssertNil(problem("storefront"))
        XCTAssertNil(problem("shop-2"))
        for bad in ["", "Shop", "my shop", "shop.local", "-shop", "shop-", String(repeating: "a", count: 41), "sh/op", "café"] { XCTAssertNotNil(problem(bad), bad) }
        XCTAssertNotNil(problem("notes-api"))                                            // another project's name there
        XCTAssertNotNil(problem("blog"))
        XCTAssertNotNil(problem("sams-macbook"))                                         // this Mac's own name on the network
        XCTAssertNotNil(problem("harbor"))
        XCTAssertNotNil(problem("headroom"))
        XCTAssertNotNil(problem("localhost"))
        XCTAssertNotNil(problem("wpad"))                                                 // what devices look up by themselves
        XCTAssertNotNil(problem("isatap"))
        XCTAssertNil(problem("wpad-notes"))
    }

    func testOnlyTheSignInPagesOwnCalls() throws {
        XCTAssertEqual(Lan.origin("storefront", port: 80), "http://storefront.local")
        XCTAssertEqual(Lan.origin("storefront", port: 8491), "http://storefront.local:8491")
        func own(_ headers: String, port: UInt16 = 80) throws -> Bool {
            let host = port == 80 ? "storefront.local" : "storefront.local:\(port)"
            let head = "POST /__harbor/enter HTTP/1.1\r\nHost: \(host)\r\n\(headers)Content-Length: 2\r\n\r\n"
            return Lan.isOwnPage(try XCTUnwrap(ProxyHead(Data(head.utf8)), headers), name: "storefront", port: port)
        }
        let json = "Content-Type: application/json\r\n"
        XCTAssertTrue(try own("Origin: http://storefront.local\r\n" + json))
        XCTAssertTrue(try own("Origin: http://storefront.local\r\nContent-Type: Application/JSON; charset=utf-8\r\nSec-Fetch-Site: same-origin\r\n"))
        XCTAssertTrue(try own("Origin: http://storefront.local:8491\r\n" + json, port: 8491))
        // Another site, another port of the same name, another project, no Origin, more than one.
        for origin in ["http://evil.example", "http://storefront.local:3000", "https://storefront.local", "http://storefront.local.evil.example", "http://notes.local",
                       "http://storefront.localhost", "null", ""] {
            XCTAssertFalse(try own("Origin: \(origin)\r\n" + json), origin)
        }
        XCTAssertFalse(try own(json))
        XCTAssertFalse(try own("Origin: http://storefront.local\r\nOrigin: http://evil.example\r\n" + json))
        XCTAssertFalse(try own("Origin: http://storefront.local\r\n" + json, port: 8491))
        // Marked by the browser as coming from another site.
        XCTAssertFalse(try own("Origin: http://storefront.local\r\nSec-Fetch-Site: cross-site\r\n" + json))
        // What a page elsewhere can post without asking first: a form, plain text, nothing.
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", "", "text/plain; application/json"] {
            XCTAssertFalse(try own("Origin: http://storefront.local\r\nContent-Type: \(type)\r\n"), type)
        }
        XCTAssertFalse(try own("Origin: http://storefront.local\r\n"))
    }

    func testANameAnotherDeviceHasMovesToTheNextFreeOne() {
        XCTAssertEqual(Lan.nextName(after: "storefront") { _ in false }, "storefront-2")
        XCTAssertEqual(Lan.nextName(after: "storefront") { ["storefront-2", "storefront-3"].contains($0) }, "storefront-4")
        // A name that is already as long as a name may be still gets one that is a name.
        let long = String(repeating: "a", count: Names.maxLength)
        let next = Lan.nextName(after: long) { _ in false }
        XCTAssertEqual(next, String(repeating: "a", count: Names.maxLength - 2) + "-2")
        XCTAssertTrue(Names.isLabel(next, max: Names.maxLength))
    }

    func testPasswords() {
        XCTAssertNotNil(Lan.passwordProblem("short"))
        XCTAssertNotNil(Lan.passwordProblem("1234567"))
        XCTAssertNil(Lan.passwordProblem("k7mqx2hw"))
        XCTAssertNotNil(Lan.passwordProblem(String(repeating: "x", count: 129)))
        // Long enough and still no password: the ones everybody tries, one character over and over,
        // a run up or down, the project's own name.
        for easy in ["12345678", "password", "Password", "PASSWORD1", "qwertyui", "iloveyou", "aaaaaaaa", "00000000000", "abcdefgh", "23456789", "87654321", "hgfedcba",
                     "storefront", "Storefront", "storefront.local", "shop-front"] {
            XCTAssertEqual(Lan.passwordProblem(easy, names: ["storefront", "shop-front"]), "That one is too easy to guess. Type another, or use a new random one.", easy)
        }
        for fine in ["correct horse 9", "storefront-77", "12345679", "abcdefgx", "aaaaaaab", "pässwörd ✓"] {
            XCTAssertNil(Lan.passwordProblem(fine, names: ["storefront"]), fine)
        }
        XCTAssertNil(Lan.passwordProblem("storefront"))                                  // somebody else's name is just a word
        // A random one: eight characters a person can read out, and not the same twice.
        let made = (0..<200).map { _ in Lan.randomPassword() }
        XCTAssertTrue(made.allSatisfy { $0.count == 8 && $0.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) } })
        XCTAssertGreaterThan(Set(made).count, 195)
        XCTAssertTrue(made.allSatisfy { Lan.passwordProblem($0) == nil })
        // Tests never touch the Keychain.
        XCTAssertTrue(Passwords.inMemory)
        XCTAssertTrue(Passwords.set("test-key", "k7mqx2hw"))
        XCTAssertEqual(Passwords.get("test-key"), "k7mqx2hw")
        Passwords.set("test-key", nil)
        XCTAssertNil(Passwords.get("test-key"))
    }

    /// Except this one, asked for by name: the real Keychain, under a throwaway service it cleans up.
    func testTheKeychainKeepsAPassword() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_KEYCHAIN_TEST"] != nil else { throw XCTSkip("set HARBOR_KEYCHAIN_TEST=1 to check the Keychain itself") }
        let service = "local.harbor.test-" + Lan.token(4), key = "/tmp/storefront"
        Passwords.inMemory = false
        defer {
            Passwords.set(key, nil, service: service)
            Passwords.inMemory = true
        }
        XCTAssertNil(Passwords.get(key, service: service))
        XCTAssertTrue(Passwords.set(key, "k7mqx2hw", service: service))
        XCTAssertEqual(Passwords.get(key, service: service), "k7mqx2hw")
        XCTAssertTrue(Passwords.set(key, "pässwörd ✓ two", service: service))             // a second one replaces the first
        XCTAssertEqual(Passwords.get(key, service: service), "pässwörd ✓ two")
        XCTAssertNil(Passwords.get("/tmp/notes", service: service))                       // one per project
        XCTAssertNil(Passwords.get(key, service: service + "-other"))
        XCTAssertTrue(Passwords.set(key, nil, service: service))
        XCTAssertNil(Passwords.get(key, service: service))
        XCTAssertTrue(Passwords.set(key, nil, service: service))                          // removing what isn't there is fine
    }

    func testTheSignInPageHoldsNothingButTheName() {
        let page = String(decoding: SignIn.page(name: "storefront"), as: UTF8.self)
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(page.contains("<h1>storefront.local</h1>"))
        let nonce = page.components(separatedBy: "script-src 'nonce-")[1].prefix { $0 != "'" }
        XCTAssertEqual(nonce.count, 32)
        XCTAssertTrue(page.contains("default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; connect-src 'self'; form-action 'none'"))
        XCTAssertTrue(page.contains("<script nonce=\"\(nonce)\">") && page.contains("<style nonce=\"\(nonce)\">"))
        XCTAssertNotEqual(nonce, String(decoding: SignIn.page(name: "storefront"), as: UTF8.self).components(separatedBy: "script-src 'nonce-")[1].prefix { $0 != "'" })
        for left in ["__NONCE__", "__NAME__", "__APP__", "__CRYPTO__", "http://", "https://", "src=", "href="] { XCTAssertFalse(page.contains(left), left) }
        XCTAssertFalse(page.contains("crypto.subtle"))                                   // it isn't there on http
        XCTAssertTrue(page.contains("function harborProof("))
        // A call harbor didn't take as the page's own has its own line; "not shared any more" is for when that is so.
        XCTAssertTrue(page.contains("if (c.status === 403) return { refused: true };"))
        XCTAssertTrue(page.contains("refused: r.status === 403 && r.data.error !== 'wrong'"))
        XCTAssertTrue(page.contains("r.refused ? \"Couldn't sign in from this page. Reload and try again.\" : r.gone ? 'This project is not shared any more.'"))
        // Everything that isn't a shared name gets a reply with nothing in it.
        XCTAssertEqual(String(decoding: Lan.bare(404), as: UTF8.self), "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
    }

    // MARK: The listener itself (real sockets)

    /// A stand-in for the project, in this process: answers every request with "ok", keeps
    /// what it was sent, and holds a WebSocket open until told to stop.
    private final class Project: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let lock = NSLock()
        private var heads: [String] = []
        private var sockets: [Int32] = []
        private var open = true
        var seen: [String] { lock.withLock { heads } }
        /// What a share of it is pinned to: this process, this port.
        var server: OnNetwork.Server {
            OnNetwork.Server(pid: getpid(), identity: LibProc.identity(getpid()), target: Names.Target(port: port, addresses: ["127.0.0.1"]))
        }

        init?() {
            guard let bound = OnNetwork.bind(0, on: "127.0.0.1") else { return nil }
            fd = bound.fd
            port = bound.port
            Thread.detachNewThread { [self] in
                while lock.withLock({ open }) {
                    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&p, 1, 100) > 0 else { continue }
                    let c = accept(fd, nil, nil)
                    guard c >= 0 else { continue }
                    guard case .ok(let head, _) = Sock.readHead(c, max: 65536, within: 2) else { close(c); continue }
                    let text = String(decoding: head, as: UTF8.self)
                    lock.withLock { heads.append(text) }
                    if text.lowercased().contains("upgrade: websocket") {
                        Sock.send(c, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8))
                        lock.withLock { sockets.append(c) }
                    } else {
                        Sock.reply(c, Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nSet-Cookie: sid=9\r\n\r\nok".utf8))
                        close(c)
                    }
                }
                close(fd)
                lock.withLock { sockets }.forEach { close($0) }
            }
        }

        /// The project's end of the WebSockets it holds: has each of them been closed from the other side?
        func socketsEnded(within seconds: Double) -> Bool {
            let held = lock.withLock { sockets }
            return !held.isEmpty && held.allSatisfy { OnNetworkTests.ended($0, within: seconds) }
        }

        func stop() { lock.withLock { open = false } }
    }

    /// True when the other side of `fd` closes within `seconds` (anything it sends first is read past).
    private static func ended(_ fd: Int32, within seconds: Double) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { return true }
        }
        return false
    }

    /// Opens a connection through `address`, sends `request`, and hands back the socket with
    /// what has arrived up to the end of the reply's head (or nothing, when it was closed).
    private func begin(_ address: String, _ port: UInt16, _ request: String) throws -> (fd: Int32, head: String) {
        let fd = try XCTUnwrap(Sock.connect([address], port: port, within: 2), "no connection to \(address):\(port)")
        _ = Array(request.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard case .ok(let head, _) = Sock.readHead(fd, max: 65536, within: 3) else { return (fd, "") }
        return (fd, String(decoding: head, as: UTF8.self))
    }

    /// One request through `address`, and everything that comes back until the other side
    /// closes. nil when nothing came back and nothing closed in 3 s.
    private func ask(_ address: String, _ port: UInt16, _ request: String) throws -> String? {
        let fd = try XCTUnwrap(Sock.connect([address], port: port, within: 2), "no connection to \(address):\(port)")
        defer { close(fd) }
        _ = Array(request.utf8).withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        var out = [UInt8](), chunk = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return String(decoding: out, as: UTF8.self) }
            out += chunk[0..<n]
        }
        return nil
    }

    private func json(_ reply: String?) -> [String: Any] {
        let body = (reply ?? "").components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]) ?? [:]
    }

    /// True once nothing listens on `address:port` any more (the listener's socket is closed a moment after sharing stops).
    private func closes(_ address: String, _ port: UInt16) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            guard let fd = Sock.connect([address], port: port, within: 0.5) else { return true }
            close(fd)
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// A socket that tries to take `address:port` for itself, the way another program on this Mac could. nil when refused.
    private func grab(_ address: String, _ port: UInt16, options: [Int32]) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        for option in options { setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &to.sin_addr)
        let bound = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        if bound { return fd }
        close(fd)
        return nil
    }

    func testTheListenerItself() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        // The listener answers what arrives on the address it announced. Here that is loopback,
        // so this needs no network and no firewall's leave; the network address has its own test below.
        let name = "storefront", password = "k7mqx2hw", here = "127.0.0.1"
        let loopback = LAN.Network(interface: "lo0", address: here, router: nil)
        let port = try XCTUnwrap(net.start(name: name, server: project.server, password: password, on: loopback, port: 0))
        let host = "\(name).local:\(port)"
        let own = "Origin: http://\(host)\r\nContent-Type: application/json\r\n"       // what harbor's own sign-in page sends
        func get(_ path: String, host: String = host, extra: String = "") throws -> String? {
            try ask(here, port, "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n")
        }
        func post(_ path: String, _ body: String, headers: String = own) throws -> String? {
            try ask(here, port, "POST \(path) HTTP/1.1\r\nHost: \(host)\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
        let nothing = String(decoding: Lan.bare(404), as: UTF8.self), refused = String(decoding: Lan.bare(403), as: UTF8.self)

        // Only a Host that is exactly a shared name is anybody's: not harbor's page, not a
        // .localhost name, not an address, not another project, not the name without the port.
        for other in ["harbor.localhost:\(port)", "\(name).localhost:\(port)", "\(here):\(port)", "blog.local:\(port)", "\(name).local", "\(name).local:80", "localhost:\(port)"] {
            XCTAssertEqual(try get("/", host: other), nothing, other)
            XCTAssertEqual(try get("/api/state", host: other), nothing, other)
        }
        // The shared name without a session: harbor's sign-in page, whatever is asked for, a WebSocket too.
        for (path, extra) in [("/", ""), ("/admin", ""), ("/hmr", "Connection: Upgrade\r\nUpgrade: websocket\r\n"), ("/", "Cookie: \(Lan.cookie)=\(Lan.token())\r\n")] {
            let page = try get(path, extra: extra) ?? ""
            XCTAssertTrue(page.hasPrefix("HTTP/1.1 401 Unauthorized\r\n") && page.contains("<h1>\(name).local</h1>"), String(page.prefix(200)))
        }
        XCTAssertEqual(try get("/__harbor/challenge"), nothing)                          // harbor's paths take a POST only
        XCTAssertTrue(project.seen.isEmpty, "nothing reached the project yet")

        // Signing in: a challenge, and the answer that proves the password without sending it.
        func challenge() throws -> (salt: String, nonce: String) {
            let c = json(try post("/__harbor/challenge", "{}"))
            XCTAssertEqual(c["iterations"] as? Int, Lan.iterations)
            return (try XCTUnwrap(c["salt"] as? String), try XCTUnwrap(c["nonce"] as? String))
        }
        func enter(_ password: String, headers: String = own) throws -> (reply: String, nonce: String, proof: String) {
            let c = try challenge()
            let proof = answer(password, salt: c.salt, name: name, nonce: c.nonce)
            return (try post("/__harbor/enter", "{\"nonce\":\"\(c.nonce)\",\"proof\":\"\(proof)\"}", headers: headers) ?? "", c.nonce, proof)
        }
        // Only harbor's own page may make the two calls. From another site (its Origin, or
        // none, or the form a page can post without asking) they are refused, and no try is counted:
        // six wrong answers that way, and the address is still not locked.
        for headers in ["Content-Type: application/json\r\n", "Origin: http://evil.example\r\nContent-Type: application/json\r\n",
                        "Origin: http://\(name).local:3000\r\nContent-Type: application/json\r\n", "Origin: null\r\nContent-Type: application/json\r\n",
                        own + "Sec-Fetch-Site: cross-site\r\n", "Origin: http://\(host)\r\nContent-Type: text/plain\r\n", "Origin: http://\(host)\r\n"] {
            XCTAssertEqual(try post("/__harbor/challenge", "{}", headers: headers), refused, headers)
            XCTAssertEqual(try enter("wrong-pass", headers: headers).reply, refused, headers)
        }
        XCTAssertTrue(try post("/__harbor/challenge", "{}", headers: own + "Sec-Fetch-Site: same-origin\r\n")?.hasPrefix("HTTP/1.1 200 ") == true)
        XCTAssertTrue(try post("/__harbor/challenge", "{}", headers: "Origin: http://\(host)\r\nContent-Type: application/json; charset=utf-8\r\n")?.hasPrefix("HTTP/1.1 200 ") == true)

        XCTAssertTrue(try enter("k7mqx2hx").reply.hasPrefix("HTTP/1.1 403 "))             // a wrong password
        let entered = try enter(password)
        XCTAssertTrue(entered.reply.hasPrefix("HTTP/1.1 200 OK\r\n"), entered.reply)
        let cookie = try XCTUnwrap(entered.reply.components(separatedBy: "\r\n").first { $0.hasPrefix("Set-Cookie: ") })
        XCTAssertTrue(cookie.hasPrefix("Set-Cookie: \(Lan.cookie)=") && cookie.hasSuffix("; Path=/; Max-Age=43200; HttpOnly; SameSite=Lax"), cookie)
        let token = String(cookie.dropFirst("Set-Cookie: \(Lan.cookie)=".count).prefix { $0 != ";" })
        XCTAssertFalse(entered.reply.contains(password) || entered.proof.contains(password))
        // The same answer a second time, or one to a made-up challenge: "start again", which is not a wrong try.
        for nonce in [entered.nonce, "1.2.3", ""] {
            let again = try post("/__harbor/enter", "{\"nonce\":\"\(nonce)\",\"proof\":\"\(entered.proof)\"}") ?? ""
            XCTAssertTrue(again.hasPrefix("HTTP/1.1 409 ") && json(again)["again"] as? Bool == true, again)
        }
        XCTAssertTrue(project.seen.isEmpty, "signing in never reaches the project")

        // With the visitor's cookie: on to the project, which sees the real Host, its own cookie, and not harbor's.
        let visitor = "Cookie: sid=9; \(Lan.cookie)=\(token)\r\n"
        let page = try get("/cart?x=1", extra: visitor) ?? ""
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 200 OK\r\n") && page.hasSuffix("\r\n\r\nok"), page)
        let sent = try XCTUnwrap(project.seen.last)
        XCTAssertTrue(sent.hasPrefix("GET /cart?x=1 HTTP/1.1\r\nHost: \(host)\r\n"), sent)
        XCTAssertTrue(sent.contains("\r\nCookie: sid=9\r\n"), sent)
        XCTAssertFalse(sent.contains(Lan.cookie) || sent.contains(token))
        // Harbor's own paths stay harbor's for a signed-in visitor: never the project's.
        var before = project.seen.count
        XCTAssertEqual(try get("/__harbor/enter", extra: visitor), nothing)
        XCTAssertEqual(try get("/__harbor/", extra: visitor), nothing)
        XCTAssertEqual(project.seen.count, before)

        // A WebSocket with the cookie goes through, and stays open.
        let upgrade = "GET /hmr HTTP/1.1\r\nHost: \(host)\r\n\(visitor)Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
        let socket = try begin(here, port, upgrade)
        defer { close(socket.fd) }
        XCTAssertTrue(socket.head.hasPrefix("HTTP/1.1 101 "), socket.head)
        XCTAssertFalse(Self.ended(socket.fd, within: 0.3))
        // A new password: everyone signs in again, and what they had open is cut at both ends, at once.
        net.setPassword("another-one", for: name)
        XCTAssertTrue(Self.ended(socket.fd, within: 1), "the visitor's end of the WebSocket")
        XCTAssertTrue(project.socketsEnded(within: 1), "the project's end of it")
        XCTAssertTrue(try get("/cart", extra: visitor)?.hasPrefix("HTTP/1.1 401 ") == true)
        XCTAssertTrue(try enter(password).reply.hasPrefix("HTTP/1.1 403 "))
        XCTAssertTrue(try enter("another-one").reply.hasPrefix("HTTP/1.1 200 "))
        // No password: straight through, and still nothing of harbor's is the project's.
        net.setPassword(nil, for: name)
        XCTAssertTrue(try get("/open")?.hasSuffix("\r\n\r\nok") == true)
        XCTAssertEqual(try post("/__harbor/enter", "{}"), nothing)

        // Nobody else can have this address and port while harbor listens on it, whatever they set on their socket.
        XCTAssertNil(grab(here, port, options: []))
        XCTAssertNil(grab(here, port, options: [SO_REUSEADDR]))
        XCTAssertNil(grab(here, port, options: [SO_REUSEADDR, SO_REUSEPORT]))
        // And when somebody else already has the port harbor wants, nothing is shared: not there, and not on another port instead.
        let second = OnNetwork(announces: false)
        XCTAssertNil(second.start(name: "notes", server: project.server, password: nil, on: loopback, port: project.port))
        XCTAssertNil(second.start(name: "notes", server: project.server, password: nil, on: loopback, port: port))
        XCTAssertEqual(second.port, 0)
        XCTAssertTrue(second.names.isEmpty)

        // Many wrong passwords for the name, from many addresses: every answer for it is held back two seconds, right or wrong.
        net.setPassword(password, for: name)
        let quick = Date()
        XCTAssertTrue(try enter(password).reply.hasPrefix("HTTP/1.1 200 "))
        XCTAssertLessThan(Date().timeIntervalSince(quick), 1)
        XCTAssertTrue(net.withVisitors { book in (0...Visitors.manyTries).map { book.wrong(address: "10.0.0.\($0 + 2)", name: name, now: Date()) }.last == true })
        let held = Date()
        XCTAssertTrue(try enter(password).reply.hasPrefix("HTTP/1.1 200 "))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(held), Visitors.slowBy)

        // Five wrong tries from one address lock it; a challenge it fetched earlier is no way round.
        net.setPassword(password, for: name)
        let early = try challenge()
        for _ in 0..<5 { XCTAssertTrue(try enter("wrong-pass").reply.hasPrefix("HTTP/1.1 403 ")) }
        let late = try post("/__harbor/enter", "{\"nonce\":\"\(early.nonce)\",\"proof\":\"\(answer(password, salt: early.salt, name: name, nonce: early.nonce))\"}") ?? ""
        XCTAssertTrue(late.hasPrefix("HTTP/1.1 429 "), late)
        XCTAssertNotNil(json(late)["wait"] as? Int)
        XCTAssertTrue(try post("/__harbor/challenge", "{}")?.hasPrefix("HTTP/1.1 429 ") == true)
        XCTAssertTrue(try get("/cart")?.hasPrefix("HTTP/1.1 401 ") == true)

        // Off the network: what is open is cut, and the listener is gone.
        net.setPassword(nil, for: name)
        let last = try begin(here, port, "GET /hmr HTTP/1.1\r\nHost: \(host)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        defer { close(last.fd) }
        XCTAssertTrue(last.head.hasPrefix("HTTP/1.1 101 "), last.head)
        net.stop(name)
        XCTAssertTrue(Self.ended(last.fd, within: 1), "turning sharing off cuts what was open")
        XCTAssertEqual(net.port, 0)
        XCTAssertTrue(closes(here, port), "the listener is gone")
        before = project.seen.count

        // A share is for one server. When that process no longer listens on that port, or it
        // is another process by now, nothing is passed on anywhere, and the owner's side is told.
        for other in [OnNetwork.Server(pid: getpid(), identity: LibProc.identity(getpid()), target: Names.Target(port: 9, addresses: [here])),
                      OnNetwork.Server(pid: getpid(), identity: "t1.1", target: project.server.target)] {
            let told = expectation(description: "the server is gone")
            net.gone = { if $0 == name { told.fulfill() } }
            let again = try XCTUnwrap(net.start(name: name, server: other, password: nil, on: loopback, port: 0))
            XCTAssertEqual(try ask(here, again, "GET / HTTP/1.1\r\nHost: \(name).local:\(again)\r\n\r\n"), String(decoding: Lan.bare(502), as: UTF8.self))
            wait(for: [told], timeout: 2)
            net.stop(name)
        }
        XCTAssertEqual(project.seen.count, before)
        XCTAssertTrue(project.server.isStillThere)
    }

    func testAFewSilentConnectionsKeepNobodyOut() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        let here = "127.0.0.1"
        let port = try XCTUnwrap(net.start(name: "storefront", server: project.server, password: nil,
                                           on: LAN.Network(interface: "lo0", address: here, router: nil), port: 0))
        let request = "GET / HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n"
        // A browser page with a few WebSockets fits; one address can't have every place there is.
        XCTAssertEqual(OnNetwork.maxPerAddress, 24)
        XCTAssertEqual(OnNetwork.maxOpen, 128)
        // One address opens as many connections as it may and says nothing on any of them.
        let began = Date()
        var silent = try (0..<OnNetwork.maxPerAddress).map { _ in try XCTUnwrap(Sock.connect([here], port: port, within: 2)) }
        defer { silent.forEach { close($0) } }
        Thread.sleep(forTimeInterval: 0.2)
        // One more from that address is closed at once, a real request or not.
        XCTAssertEqual(try ask(here, port, request), "")
        // When one of them lets go there is room again.
        close(silent.removeFirst())
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(try ask(here, port, request)?.hasSuffix("\r\n\r\nok") == true)
        // And none of them is held for long: a head has to arrive within five seconds.
        XCTAssertEqual(OnNetwork.headWithin, 5)
        XCTAssertFalse(Self.ended(silent[0], within: 3.5 - Date().timeIntervalSince(began)))
        XCTAssertTrue(silent.allSatisfy { Self.ended($0, within: 6.5 - Date().timeIntervalSince(began)) })
    }

    /// A socket that tries to take `port` on IPv6 for itself: every interface, or one address. nil when refused.
    private func grab6(_ port: UInt16, at address: String = "::", options: [Int32], only6: Bool = true) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        var one: Int32 = 1, v6only: Int32 = only6 ? 1 : 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
        for option in options { setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size)) }
        var to = sockaddr_in6()
        to.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        to.sin6_family = sa_family_t(AF_INET6)
        to.sin6_port = port.bigEndian
        inet_pton(AF_INET6, address, &to.sin6_addr)
        let bound = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 } }
        if bound, listen(fd, 4) == 0 { return fd }
        close(fd)
        return nil
    }

    func testTheSamePortOnIPv6IsHeldAndServesNothing() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        let loopback = LAN.Network(interface: "lo0", address: "127.0.0.1", router: nil)
        let port = try XCTUnwrap(net.start(name: "storefront", server: project.server, password: nil, on: loopback, port: 0))
        // While something is shared harbor has the port on IPv6 too, so nobody can answer there in a shared name's place.
        XCTAssertTrue(net.holdsIPv6)
        for options in [[], [SO_REUSEADDR], [SO_REUSEADDR, SO_REUSEPORT]] as [[Int32]] {
            XCTAssertNil(grab6(port, options: options), "\(options)")
            XCTAssertNil(grab6(port, options: options, only6: false), "\(options), both families")
        }
        // Harbor serves nothing there: whatever arrives is closed without a word, right Host or not.
        XCTAssertEqual(try ask("::1", port, "GET / HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n"), "")
        XCTAssertTrue(project.seen.isEmpty)
        XCTAssertTrue(try ask("127.0.0.1", port, "GET / HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n")?.hasSuffix("\r\n\r\nok") == true)
        // Sharing over: the port is let go on both.
        net.stop("storefront")
        XCTAssertFalse(net.holdsIPv6)
        XCTAssertTrue(closes("127.0.0.1", port))
        var taken: Int32?
        for _ in 0..<50 where taken == nil {
            taken = grab6(port, options: [SO_REUSEADDR])
            if taken == nil { Thread.sleep(forTimeInterval: 0.02) }
        }
        let free = try XCTUnwrap(taken, "let go when sharing stops")
        // Another program had it first: sharing works all the same, and harbor knows it doesn't hold it.
        defer { close(free) }
        XCTAssertEqual(net.start(name: "storefront", server: project.server, password: nil, on: loopback, port: port), port)
        XCTAssertFalse(net.holdsIPv6)
        XCTAssertTrue(try ask("127.0.0.1", port, "GET / HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n")?.hasSuffix("\r\n\r\nok") == true)
    }

    func testAQuietWebSocketIsClosed() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        XCTAssertEqual(OnNetwork(announces: false).quietSocket, 600)                      // ten minutes; here half a second
        let net = OnNetwork(announces: false, quietSocket: 0.5)
        defer { net.stopAll() }
        let port = try XCTUnwrap(net.start(name: "storefront", server: project.server, password: nil,
                                           on: LAN.Network(interface: "lo0", address: "127.0.0.1", router: nil), port: 0))
        let socket = try begin("127.0.0.1", port, "GET /hmr HTTP/1.1\r\nHost: storefront.local:\(port)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        defer { close(socket.fd) }
        XCTAssertTrue(socket.head.hasPrefix("HTTP/1.1 101 "), socket.head)
        XCTAssertFalse(Self.ended(socket.fd, within: 0.25))
        XCTAssertTrue(Self.ended(socket.fd, within: 1.5), "nothing passed either way: closed")
        XCTAssertTrue(project.socketsEnded(within: 1))
    }

    /// Port 80 is heard on every interface, so there the announced address is what decides.
    /// A port under 1024 stands in for it (not 80: that one is harbor's own door).
    private func lowPort(_ net: OnNetwork, _ project: Project, on network: LAN.Network) throws -> UInt16 {
        for port in stride(from: UInt16(1023), to: 1000, by: -1) {
            if let got = net.start(name: "storefront", server: project.server, password: nil, on: network, port: port) { return got }
        }
        throw XCTSkip("no free port under 1024 to stand in for port 80")
    }

    func testOnEveryInterfaceOnlyTheAnnouncedAddressIsAnswered() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        XCTAssertTrue(OnNetwork.hearsEveryInterface(80))
        XCTAssertFalse(OnNetwork.hearsEveryInterface(8080) || OnNetwork.hearsEveryInterface(0))
        // Announced on an address that isn't loopback: the listener hears loopback (it hears every
        // interface) but closes what arrives there without a word, right Host and no password or not.
        let port = try lowPort(net, project, on: LAN.Network(interface: "en0", address: "192.0.2.24", router: nil))
        XCTAssertEqual(try ask("127.0.0.1", port, "GET / HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n"), "")
        XCTAssertTrue(project.seen.isEmpty)
        // And on a low port nobody without root can take one address from under it, with any option.
        for address in ["127.0.0.1", LAN.ipv4()].compactMap({ $0 }) {
            XCTAssertNil(grab(address, port, options: [SO_REUSEADDR]), address)
            XCTAssertNil(grab(address, port, options: [SO_REUSEADDR, SO_REUSEPORT]), address)
        }
        XCTAssertNil(grab("0.0.0.0", port, options: [SO_REUSEADDR, SO_REUSEPORT]))
        // The same on IPv6: harbor holds every interface there, and one address on a low port needs root.
        XCTAssertTrue(net.holdsIPv6)
        XCTAssertNil(grab6(port, options: [SO_REUSEADDR, SO_REUSEPORT]))
        XCTAssertNil(grab6(port, at: "::1", options: [SO_REUSEADDR, SO_REUSEPORT]))
    }

    /// The same through this Mac's real network address, which is how another device arrives.
    /// Asked for by name, because a firewall may ask about it.
    func testThroughTheNetworkAddress() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_LAN_TEST"] != nil else { throw XCTSkip("set HARBOR_LAN_TEST=1 to check the listener through this Mac's network address") }
        guard let network = LAN.current() else { throw XCTSkip("this Mac is on no network") }
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        let port = try lowPort(net, project, on: network)
        let request = "GET /cart HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\r\n"
        XCTAssertEqual(try ask("127.0.0.1", port, request), "")                          // not the announced address: nothing
        XCTAssertTrue(project.seen.isEmpty)
        guard let reply = try ask(network.address, port, request) else {
            throw XCTSkip("nothing came back through \(network.address): a firewall is holding connections to the test runner")
        }
        XCTAssertTrue(reply.hasSuffix("\r\n\r\nok"), reply)
        XCTAssertEqual(project.seen.count, 1)
        XCTAssertEqual(try ask(network.address, port, "GET / HTTP/1.1\r\nHost: \(network.address):\(port)\r\n\r\n"), String(decoding: Lan.bare(404), as: UTF8.self))
    }
}
