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
        let phone = "192.168.1.30"
        let token = visitors.signIn(to: "storefront", from: phone, now: t0)
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0.addingTimeInterval(11 * 3600)))
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0.addingTimeInterval(12 * 3600 + 1)))   // twelve hours
        XCTAssertFalse(visitors.isSignedIn(token, to: "notes", from: phone, now: t0))                                           // for that name only
        XCTAssertFalse(visitors.isSignedIn(nil, to: "storefront", from: phone, now: t0))
        XCTAssertFalse(visitors.isSignedIn("", to: "storefront", from: phone, now: t0))
        XCTAssertFalse(visitors.isSignedIn(token + "x", to: "storefront", from: phone, now: t0))
        XCTAssertFalse(visitors.isSignedIn(String(token.dropLast()), to: "storefront", from: phone, now: t0))
        // And for the address it was signed in from only: from any other the cookie is no session at all.
        for elsewhere in ["192.168.1.31", "192.168.1.3", "192.168.1.300", "10.168.1.30", "127.0.0.1", "::1", ""] {
            XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", from: elsewhere, now: t0), elsewhere)
            XCTAssertFalse(visitors.inUse(token, on: "storefront", from: elsewhere, now: t0), elsewhere)
        }
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0))                    // asking from elsewhere spoiled nothing
        let nowhere = visitors.signIn(to: "storefront", from: "", now: t0)
        XCTAssertFalse(visitors.isSignedIn(nowhere, to: "storefront", from: "", now: t0))                    // no address: nobody's
        // The browser signs in again (it has a new address): the session it had is over, and only that one.
        let other = visitors.signIn(to: "storefront", from: "192.168.1.40", now: t0)
        XCTAssertFalse(visitors.end(token, on: "notes"))                                                     // a cookie for another name ends nothing
        XCTAssertFalse(visitors.end("0000", on: "storefront"))
        XCTAssertFalse(visitors.end(nil, on: "storefront"))
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0))
        XCTAssertTrue(visitors.end(token, on: "storefront"))
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0))
        XCTAssertFalse(visitors.end(token, on: "storefront"))
        XCTAssertTrue(visitors.isSignedIn(other, to: "storefront", from: "192.168.1.40", now: t0))
        // Sharing stops, or the password changes: everyone signs in again.
        visitors.forget("storefront")
        XCTAssertFalse(visitors.isSignedIn(other, to: "storefront", from: "192.168.1.40", now: t0))
        XCTAssertEqual(token.count, 48)
        XCTAssertNotEqual(token, visitors.signIn(to: "storefront", from: phone, now: t0))
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
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: "192.168.1.30", now: t0))
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront", from: "192.168.1.66", now: t0))          // the session is for the address that answered
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
            _ = visitors.signIn(to: "storefront", from: "10.\(i / 65536).\(i / 256 % 256).\(i % 256)", now: t0)
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

    /// On the network an address is who a visitor is. One that can't be read is never made
    /// up: it is empty, the listener closes such a connection, and nothing is said for it.
    func testAnAddressThatCantBeReadIsNobodys() throws {
        XCTAssertEqual(Sock.peer(-1), "")
        XCTAssertEqual(Sock.local(-1), "")
        // A socket that was never connected has no other end.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        XCTAssertEqual(Sock.peer(fd), "")
        // It is not the announced address, so the listener wouldn't answer it; and no session, try or place hangs on it.
        XCTAssertFalse(Lan.accepts(local: "", announced: "192.168.1.24"))
        XCTAssertFalse(Lan.accepts(local: "", announced: nil))
        var visitors = Visitors()
        let token = visitors.signIn(to: "storefront", project: "/code/storefront", from: "", now: t0)
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: "/code/storefront", address: "", now: t0, open: [token]))
        // The project isn't told an address nobody read (on the .localhost side, where this is all an address is for).
        let request = try XCTUnwrap(ProxyHead(Data("GET / HTTP/1.1\r\nHost: storefront.localhost\r\nX-Forwarded-For: 6.6.6.6\r\n\r\n".utf8)))
        XCTAssertFalse(String(decoding: request.forwarded(client: ""), as: UTF8.self).lowercased().contains("x-forwarded-for"))
        XCTAssertTrue(String(decoding: request.forwarded(client: "127.0.0.1"), as: UTF8.self).contains("\r\nX-Forwarded-For: 127.0.0.1\r\n"))
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
        XCTAssertEqual(Set((shared ?? [:]).keys), ["name", "on", "link", "password", "trouble", "main", "several", "note", "help", "anyone", "left"])
        XCTAssertTrue(shared?["trouble"] is NSNull)                                       // announced: nothing to say
        XCTAssertEqual(shared?["main"] as? Bool, true)
        XCTAssertEqual(shared?["several"] as? Bool, true)                                // the storefront has a second server
        XCTAssertEqual(shared?["note"] as? String, Lan.passwordNote(project: "storefront", several: true, devices: 0))
        XCTAssertEqual((shared?["note"] as? String)?.hasSuffix("Devices behind one address count as one."), true)
        XCTAssertTrue(shared?["help"] is NSNull)                                         // only one of them is on the network
        // The project's other server has a switch of its own, and its own name there.
        let second = rows.first { ($0["port"] as? Int) == 3001 }?["local"] as? [String: Any]
        XCTAssertEqual(second?["on"] as? Bool, false)
        XCTAssertEqual(second?["main"] as? Bool, false)
        XCTAssertEqual((second?["name"] as? String)?.hasPrefix("storefront-3001"), true)
        XCTAssertEqual(second?["password"] as? Bool, shared?["password"] as? Bool)        // the project's one
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
        XCTAssertEqual(m.lanShares.count, 1)
        m.stopAllSharing()
        // A row whose process isn't there (any more) can't go on the network: the made-up Mac's servers don't exist on this one.
        XCTAssertEqual(m.shareOnNetwork(second, open: true), "storefront on port 3001 isn't running any more.")
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
        // Tests keep them in memory, like debug runs.
        XCTAssertTrue(Passwords.inMemory)
        XCTAssertTrue(Passwords.set("test-key", "k7mqx2hw"))
        XCTAssertEqual(Passwords.read("test-key"), .password("k7mqx2hw"))
        Passwords.set("test-key", nil)
        XCTAssertEqual(Passwords.read("test-key"), .none)
    }

    func testWhichCodesARowShows() {
        func codes(onNetwork: Bool = false, reachable: Bool = false, shared: Bool = false) -> [QR.Code] { QR.codes(onNetwork: onNetwork, reachable: reachable, shared: shared) }
        XCTAssertEqual(codes(), [])                                                       // this Mac only, not shared: none
        XCTAssertEqual(codes(reachable: true), [.lan])                                    // its plain address, as ever
        XCTAssertEqual(codes(shared: true), [.share])
        XCTAssertEqual(codes(onNetwork: true), [.name])
        XCTAssertEqual(codes(onNetwork: true, shared: true), [.name, .share])             // both ways: both codes
        XCTAssertEqual(codes(reachable: true, shared: true), [.lan, .share])
        // Never three: on the network, its name stands in for the plain address.
        XCTAssertEqual(codes(onNetwork: true, reachable: true), [.name])
        XCTAssertEqual(codes(onNetwork: true, reachable: true, shared: true), [.name, .share])
    }

    @MainActor
    func testBothCodesAndTheNamesAsThePageIsTold() {
        // The made-up storefront: on every interface, on the network, and with a public link that is ready.
        let (m, name, rows) = sharedFixture()
        Tunnels.shared.useFixture(port: 3000, title: "storefront", url: "https://quiet-harbor-demo.trycloudflare.com")
        defer { Tunnels.shared.stop(3000) }
        let main = rows.first { $0.port == 3000 }!
        XCTAssertEqual(m.codes(main).map(\.code), [.name, .share])
        XCTAssertEqual(m.codes(main).map(\.label), ["On your network", "Public link"])
        XCTAssertEqual(m.codes(main).map(\.link), ["http://\(name).local/", "https://quiet-harbor-demo.trycloudflare.com"])
        var state: [String: Any] = [:]
        WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
        let told = ((state["ports"] as? [[String: Any]]) ?? []).first { ($0["port"] as? Int) == 3000 }?["qrs"] as? [[String: String]]
        XCTAssertEqual(told?.map { $0["kind"] }, ["name", "share"])
        XCTAssertEqual(told?.map { $0["link"] }, ["http://\(name).local/", "https://quiet-harbor-demo.trycloudflare.com"])
        // Off the network it is back to its plain address, beside the public link.
        m.stopAllSharing()
        XCTAssertEqual(m.codes(main).map(\.code), [.lan, .share])
        XCTAssertEqual(m.codes(main).first?.link, "http://192.168.1.24:3000/")
        // A server only this Mac reaches, not shared: nothing to scan.
        XCTAssertTrue(m.codes(rows.first { $0.port == 8000 }!).isEmpty)
    }

    @MainActor
    func testRenamingOnThisMacLeavesTheNetworkAlone() {
        // On the network under the name it got from its .localhost name; then that one is renamed.
        let (m, name, rows) = sharedFixture()
        let main = rows.first { $0.port == 3000 }!, key = Names.key(main)
        let notices = m.notices.last?.id
        XCTAssertNil(m.rename(main, to: "shop"))
        defer { _ = m.rename(main, to: "") }
        XCTAssertEqual(m.names.base[key], "shop")
        // What is on the network stays exactly as it was: same name, same link, nothing dropped, nothing said.
        XCTAssertEqual(m.lanShares[main.id]?.name, name)
        XCTAssertEqual(m.networkLink(main), "http://\(name).local/")
        XCTAssertEqual(m.notices.last?.id, notices)
        // The next time it is turned on it would take the new name, unless it has one of its own there.
        m.stopAllSharing()
        XCTAssertEqual(m.networkName(main)?.hasPrefix("shop"), true)
    }

    // MARK: Several servers of one project

    @MainActor
    func testTheMainServerCanBeChosen() {
        var (m, _, rows) = sharedFixture()
        let front = rows.first { $0.port == 3000 }!, back = rows.first { $0.port == 3001 }!, project = Names.key(front)
        m.stopAllSharing()
        _ = m.makeMain(front)                                                            // whatever an earlier run chose
        // By the usual rule the plain name goes to the dev server on the lowest port; the other goes by its port.
        XCTAssertTrue(m.isMain(front) && !m.isMain(back))
        XCTAssertEqual(m.names.byRow[back.id], "storefront-3001")
        XCTAssertEqual(m.networkName(back)?.hasPrefix("storefront-3001"), true)
        // The rule itself: a chosen main takes the name outright, even from the server that has it; the one that had it goes by its port.
        var table = Names.assign(rows, previous: m.names, mains: [project: 3001])
        XCTAssertEqual(table.byRow[back.id], "storefront")
        XCTAssertEqual(table.byRow[front.id], "storefront-3000")
        XCTAssertEqual(table.targets["storefront"]?.port, 3001)
        XCTAssertNil(table.targets["storefront-3001"])
        XCTAssertEqual(table.base[project], "storefront")
        // The chosen server isn't running: the usual rule decides, and nothing else changes.
        table = Names.assign(rows.filter { $0.port != 3001 }, previous: m.names, mains: [project: 3001])
        XCTAssertEqual(table.byRow[front.id], "storefront")
        table = Names.assign(rows, previous: m.names, mains: [project: 9999])
        XCTAssertEqual(table.byRow[front.id], "storefront")
        XCTAssertEqual(table.byRow[back.id], "storefront-3001")
        // Another project's choice is nobody else's.
        XCTAssertEqual(Names.assign(rows, previous: m.names, mains: ["/Users/sam/code/notes-api": 3001]).byRow[front.id], "storefront")

        // In the app, with the project on the network: choosing the other server takes what is on the network off it
        // (said in a notice), so no name there starts opening another server by itself.
        (m, _, rows) = sharedFixture()
        XCTAssertEqual(m.lanShares.count, 1)
        let before = m.notices.last?.id
        XCTAssertNil(m.makeMain(back))
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertNotEqual(m.notices.last?.id, before)
        XCTAssertEqual(m.notices.last?.text.hasPrefix("The main server of storefront changed, so "), true)
        XCTAssertEqual(m.notices.last?.text.hasSuffix(" is off the network. Turn it on again."), true)
        XCTAssertTrue(m.isMain(back) && !m.isMain(front))
        XCTAssertEqual(m.names.byRow[front.id], "storefront-3000")
        XCTAssertEqual(m.networkName(back)?.hasPrefix("storefront"), true)
        XCTAssertEqual(m.networkName(front)?.hasPrefix("storefront-3000"), true)
        // The chosen one stops: the usual rule again. It comes back: it is the main one again, without being chosen twice.
        m.useFixture(rows.filter { $0.port != 3001 }, shared: nil)
        XCTAssertTrue(m.isMain(front))
        m.useFixture(rows, shared: nil)
        XCTAssertTrue(m.isMain(back))
        XCTAssertNil(m.makeMain(back))                                                   // already is: nothing happens
        XCTAssertNil(m.makeMain(front))                                                  // and back, for the tests after this one
        XCTAssertTrue(m.isMain(front))
        XCTAssertNotNil(m.makeMain(rows.first { $0.port == 5432 }!))                     // a database has no name to be main of
    }

    @MainActor
    func testEveryServerHasItsOwnSwitchAndTheHeaderCountsThem() {
        let (m, name, rows) = sharedFixture()
        let front = rows.first { $0.port == 3000 }!, back = rows.first { $0.port == 3001 }!
        // Any server with a name can go on the network; one without (a database) can't.
        XCTAssertTrue(m.isNetworkRow(front) && m.isNetworkRow(back) && m.isNetworkRow(rows.first { $0.port == 8000 }!))
        XCTAssertFalse(m.isNetworkRow(rows.first { $0.port == 5432 }!))
        XCTAssertTrue(m.hasSiblings(front) && m.hasSiblings(back))
        XCTAssertFalse(m.hasSiblings(rows.first { $0.port == 8000 }!))
        // Only the front one is on: the back one has its own name ready, and isn't on because its sibling is.
        XCTAssertEqual(m.networkLink(front), "http://\(name).local/")
        XCTAssertNil(m.networkLink(back))
        XCTAssertEqual(m.codes(back).map(\.code), [])
        XCTAssertEqual(m.portNotes.first, "1 project on your network")
        // Renaming one on the network is that server's alone.
        XCTAssertNil(m.renameOnNetwork(back, to: "api"))
        XCTAssertEqual(m.networkName(back)?.hasPrefix("api"), true)
        XCTAssertEqual(m.lanShares[front.id]?.name, name)
        XCTAssertNotNil(m.renameOnNetwork(back, to: "storefront"))                        // its sibling's name
        XCTAssertNil(m.renameOnNetwork(back, to: ""))
        XCTAssertEqual(m.networkName(back)?.hasPrefix("storefront-3001"), true)
        // What the header says, by what is on the network.
        XCTAssertEqual(Lan.passwordNote(project: "storefront", several: false, devices: 0), nil)
        XCTAssertEqual(Lan.passwordNote(project: "storefront", several: true, devices: 0), "One password for all of storefront's servers on the network, and one sign-in: after a device signs in to one of them, storefront's own pages can call the others from that device, while it keeps using the one it signed in to (up to 15 minutes after its last request there). Devices behind one address count as one.")
        XCTAssertEqual(Lan.passwordNote(project: "storefront", several: false, devices: 1), "1 device signed in. A new password signs it out.")
        XCTAssertEqual(Lan.passwordNote(project: "storefront", several: true, devices: 2)?.hasSuffix("Devices behind one address count as one. 2 devices signed in. A new password signs them out."), true)
    }

    /// There is one password per project. Taking it away, or sharing without one, opens every
    /// server of the project that is on the network: the question asked first says so.
    @MainActor
    func testGoingWithoutAPasswordNamesEveryServerItOpens() {
        XCTAssertEqual(Lan.anyoneCanOpen(name: "storefront", project: "storefront", servers: 1), "Anyone on this Wi-Fi can open storefront.")
        XCTAssertEqual(Lan.anyoneCanOpen(name: "api", project: "storefront", servers: 2), "Anyone on this Wi-Fi can open storefront's 2 servers on the network.")
        XCTAssertEqual(Lan.anyoneCanOpen(name: "api", project: "storefront", servers: 3), "Anyone on this Wi-Fi can open storefront's 3 servers on the network.")
        func told(_ port: Int) -> String? {
            var state: [String: Any] = [:]
            WebAPI.state { state = ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }
            return (((state["ports"] as? [[String: Any]]) ?? []).first { ($0["port"] as? Int) == port }?["local"] as? [String: Any])?["anyone"] as? String
        }
        // Only the front end is on. Removing its password opens that one; turning the back end on without one makes it two.
        let (m, name, rows) = sharedFixture()
        let front = rows.first { $0.port == 3000 }!, back = rows.first { $0.port == 3001 }!, other = rows.first { $0.port == 8000 }!
        XCTAssertEqual(m.anyoneCanOpen(front), "Anyone on this Wi-Fi can open \(name).")
        XCTAssertEqual(m.anyoneCanOpen(back), "Anyone on this Wi-Fi can open storefront's 2 servers on the network.")
        XCTAssertEqual(m.anyoneCanOpen(other), "Anyone on this Wi-Fi can open \(m.networkName(other) ?? "").")        // another project: its own count
        XCTAssertEqual(told(3000), m.anyoneCanOpen(front))                                                            // the page asks with the same words
        XCTAssertEqual(told(3001), m.anyoneCanOpen(back))
        // Both are on: taking the password away on either one is said for both.
        m.useFixture(rows, shared: Names.key(front), every: true)
        XCTAssertEqual(m.lanShares.count, 2)
        XCTAssertEqual(m.anyoneCanOpen(front), "Anyone on this Wi-Fi can open storefront's 2 servers on the network.")
        XCTAssertEqual(m.anyoneCanOpen(back), "Anyone on this Wi-Fi can open storefront's 2 servers on the network.")
        XCTAssertEqual(told(3001), "Anyone on this Wi-Fi can open storefront's 2 servers on the network.")
        m.stopAllSharing()
    }

    /// A name given to a server on the network is that server's: it doesn't go with the "main" role to another one.
    @MainActor
    func testANameOnTheNetworkStaysWithItsServer() {
        let (m, _, rows) = sharedFixture()
        let front = rows.first { $0.port == 3000 }!, back = rows.first { $0.port == 3001 }!
        m.stopAllSharing()
        _ = m.makeMain(front)
        defer { _ = m.renameOnNetwork(front, to: ""); _ = m.makeMain(front) }
        XCTAssertNil(m.renameOnNetwork(front, to: "rvfront"))
        XCTAssertEqual(m.networkName(front), "rvfront" + DebugCLI.lanSuffix)
        // The back end becomes the main server: it gets the name a main server has by itself, not the front end's.
        XCTAssertNil(m.makeMain(back))
        XCTAssertTrue(m.isMain(back))
        XCTAssertEqual(m.networkName(back), "storefront" + DebugCLI.lanSuffix)
        XCTAssertEqual(m.networkName(front), "rvfront" + DebugCLI.lanSuffix)
        // And a name of its own it keeps when it stops being the main one.
        XCTAssertNil(m.renameOnNetwork(back, to: "rvapi"))
        XCTAssertNil(m.makeMain(front))
        XCTAssertEqual(m.networkName(back), "rvapi" + DebugCLI.lanSuffix)
        XCTAssertEqual(m.networkName(front), "rvfront" + DebugCLI.lanSuffix)
        XCTAssertNil(m.renameOnNetwork(back, to: ""))
        XCTAssertEqual(m.networkName(back), "storefront-3001" + DebugCLI.lanSuffix)

        // What 1.4 saved by folder alone is handed to the server that is main now, once; and stays there.
        let old = ["/code/shop": "rvfront", "/code/notes": "pad", "/code/blog\t4000": "posts", "/code/idle": "later"]
        let moved = Monitor.handedOver(old, mains: ["/code/shop": 5173, "/code/notes": 8000, "/code/blog": 4000])
        XCTAssertEqual(moved, ["/code/shop\t5173": "rvfront", "/code/notes\t8000": "pad", "/code/blog\t4000": "posts", "/code/idle": "later"])   // not running: waits
        XCTAssertEqual(Monitor.handedOver(moved, mains: ["/code/shop": 3001, "/code/notes": 8000, "/code/idle": 9000])["/code/shop\t5173"], "rvfront")
        XCTAssertNil(Monitor.handedOver(moved, mains: ["/code/shop": 3001])["/code/shop\t3001"])                     // another main later gets nothing of it
        // A name the main server already has of its own wins; the old entry is gone either way.
        XCTAssertEqual(Monitor.handedOver(["/code/shop": "old", "/code/shop\t5173": "mine"], mains: ["/code/shop": 5173]), ["/code/shop\t5173": "mine"])
    }

    func testOneSignInForAProjectsServers() {
        var visitors = Visitors()
        let phone = "192.168.1.30", project = "/Users/sam/code/storefront"
        // Nobody signed in: no name of the project opens for anybody.
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0))
        let token = visitors.signIn(to: "storefront", project: project, from: phone, now: t0)
        // The phone signed in on the front end: from its address the project's other names open without a cookie…
        XCTAssertEqual(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0)?.name, "storefront")
        XCTAssertEqual(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0)?.session, token)
        XCTAssertEqual(visitors.sibling(of: "api", project: project, address: phone, now: t0)?.name, "storefront")
        // …the name it signed in on opens with its cookie only (nothing on another name stands behind it)…
        XCTAssertNil(visitors.sibling(of: "storefront", project: project, address: phone, now: t0))
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0))
        XCTAssertFalse(visitors.isSignedIn(token, to: "storefront-8000", from: phone, now: t0))        // and the cookie is for that name only
        // …another device gets nothing from it, and neither does another project, at the same address or not.
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: "192.168.1.31", now: t0))
        XCTAssertNil(visitors.sibling(of: "notes-api", project: "/Users/sam/code/notes-api", address: phone, now: t0))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: "/Users/sam/code/storefront-2", address: phone, now: t0))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: "", address: phone, now: t0))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: "", now: t0))
        // It never lasts longer than the session, however much that is in use.
        XCTAssertNotNil(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0.addingTimeInterval(12 * 3600 - 1), open: [token]))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0.addingTimeInterval(12 * 3600), open: [token]))
        // How many devices are in: by address, however often each signed in.
        _ = visitors.signIn(to: "storefront-8000", project: project, from: phone, now: t0)
        _ = visitors.signIn(to: "storefront", project: project, from: "192.168.1.31", now: t0)
        _ = visitors.signIn(to: "notes-api", project: "/Users/sam/code/notes-api", from: "192.168.1.40", now: t0)
        XCTAssertEqual(visitors.devices(project: project, now: t0), 2)
        XCTAssertEqual(visitors.devices(project: project, now: t0.addingTimeInterval(12 * 3600)), 0)
        // The session ends (sharing of that name stopped, or the password changed): what rested on it is gone with it.
        visitors.forget("storefront-8000")
        XCTAssertEqual(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0)?.name, "storefront")   // the other session still stands
        visitors.forget("storefront")
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: phone, now: t0))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: "192.168.1.31", now: t0))
        XCTAssertEqual(visitors.devices(project: project, now: t0), 0)
        // Nothing here grows without bound: it is the sessions, and those are counted.
        for i in 0..<3000 { _ = visitors.signIn(to: "storefront", project: project, from: "10.0.\(i / 256).\(i % 256)", now: t0) }
        XCTAssertLessThanOrEqual(visitors.counts.sessions, Visitors.maxSessions)
    }

    /// An address keeps a project's other names only while the session it signed in with is
    /// in use from it: a visitor who has left hands nothing on to whoever gets the address next.
    func testTheWayInLastsOnlyWhileTheSessionIsInUse() {
        var visitors = Visitors()
        let phone = "192.168.1.30", project = "/Users/sam/code/storefront"
        let token = visitors.signIn(to: "storefront", project: project, from: phone, now: t0)
        func open(at seconds: TimeInterval, held: Set<String> = [], from address: String = "192.168.1.30") -> Bool {
            visitors.sibling(of: "storefront-8000", project: project, address: address, now: t0.addingTimeInterval(seconds), open: held) != nil
        }
        XCTAssertEqual(Visitors.grantLife, 900)
        // Signing in is the first use: fifteen minutes from there, and not a second more.
        XCTAssertTrue(open(at: 0))
        XCTAssertTrue(open(at: 899))
        XCTAssertFalse(open(at: 900))
        XCTAssertFalse(open(at: 3600))
        // The session itself is as good as ever: on its own name the cookie still opens.
        XCTAssertTrue(visitors.isSignedIn(token, to: "storefront", from: phone, now: t0.addingTimeInterval(3600)))
        // Asking (a request let in this way, or turned away) is not use: nothing is kept alive by it.
        for minute in stride(from: 0.0, through: 14, by: 2) { XCTAssertTrue(open(at: minute * 60)) }
        XCTAssertFalse(open(at: 900))
        // The cookie comes from that address again: in use, for fifteen minutes from then.
        XCTAssertTrue(visitors.inUse(token, on: "storefront", from: phone, now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(open(at: 3600))
        XCTAssertTrue(open(at: 3600 + 899))
        XCTAssertFalse(open(at: 3600 + 900))
        // Not by the cookie from another address (and that address gets nothing either), a cookie that isn't one,
        // none at all, or the cookie on a name it isn't for.
        let later = t0.addingTimeInterval(7200)
        XCTAssertFalse(visitors.inUse(token, on: "storefront", from: "192.168.1.31", now: later))
        XCTAssertFalse(visitors.inUse("0000", on: "storefront", from: phone, now: later))
        XCTAssertFalse(visitors.inUse(nil, on: "storefront", from: phone, now: later))
        XCTAssertFalse(visitors.inUse(token, on: "storefront-8000", from: phone, now: later))
        XCTAssertFalse(open(at: 7200))
        XCTAssertFalse(open(at: 7200, from: "192.168.1.31"))
        // A connection that came with the cookie and is still open (a hot-reload socket) keeps it alive for as long
        // as it is open: that session's, nobody else's, and never past the session's own end.
        XCTAssertTrue(open(at: 7200, held: [token]))
        XCTAssertTrue(open(at: 11 * 3600, held: [token]))
        XCTAssertFalse(open(at: 7200, held: ["another-session"]))
        XCTAssertFalse(open(at: 7200, held: [token], from: "192.168.1.31"))
        XCTAssertFalse(open(at: 12 * 3600, held: [token]))
        XCTAssertFalse(visitors.inUse(token, on: "storefront", from: phone, now: t0.addingTimeInterval(12 * 3600)))
        // The phone gets a new address. Its cookie is no session from there, and opens nothing there; it signs in again
        // (the old session ends with that), and from then on the way in is the new address's alone.
        var visitors2 = Visitors()
        let old = visitors2.signIn(to: "storefront", project: project, from: phone, now: t0), moved = "192.168.1.77"
        XCTAssertFalse(visitors2.inUse(old, on: "storefront", from: moved, now: t0))
        XCTAssertNil(visitors2.sibling(of: "storefront-8000", project: project, address: moved, now: t0))
        XCTAssertNotNil(visitors2.sibling(of: "storefront-8000", project: project, address: phone, now: t0))       // not yet replaced: the old address still has its fifteen minutes
        let new = visitors2.signIn(to: "storefront", project: project, from: moved, now: t0)
        XCTAssertTrue(visitors2.end(old, on: "storefront"))
        XCTAssertEqual(visitors2.sibling(of: "storefront-8000", project: project, address: moved, now: t0)?.session, new)
        XCTAssertNil(visitors2.sibling(of: "storefront-8000", project: project, address: phone, now: t0, open: [old, new]))
        XCTAssertFalse(visitors2.isSignedIn(new, to: "storefront", from: phone, now: t0))
        XCTAssertEqual(visitors2.devices(project: project, now: t0), 1)                                           // one device, counted once
        // A session signed in from no readable address is nobody's way in.
        let nowhere = visitors.signIn(to: "storefront", project: project, from: "", now: t0)
        XCTAssertFalse(visitors.inUse(nowhere, on: "storefront", from: "", now: t0))
        XCTAssertNil(visitors.sibling(of: "storefront-8000", project: project, address: "", now: t0, open: [nowhere]))
    }

    /// Which of a project's pages a request says it comes from. Read strictly: this is what
    /// keeps another site's page, open on a signed-in device, away from the project's servers.
    func testWhereARequestSaysItComesFrom() throws {
        let names = ["storefront", "storefront-8000"]
        func page(_ headers: String, port: UInt16 = 80) throws -> String? {
            Lan.page(of: try XCTUnwrap(ProxyHead(Data("GET /api/items HTTP/1.1\r\nHost: storefront-8000.local\r\n\(headers)\r\n".utf8))), port: port, names: names)
        }
        // A page's fetch, its preflight, a WebSocket, an EventSource: Origin, exactly the name's.
        XCTAssertEqual(try page("Origin: http://storefront.local\r\n"), "storefront")
        XCTAssertEqual(try page("Origin: http://storefront-8000.local\r\n"), "storefront-8000")
        XCTAssertEqual(try page("Origin: http://storefront.local:8491\r\n", port: 8491), "storefront")
        // An image, a script, a link that was followed: no Origin, and the Referer starts with it.
        XCTAssertEqual(try page("Referer: http://storefront.local/\r\n"), "storefront")
        XCTAssertEqual(try page("Referer: http://storefront.local/cart?step=2\r\n"), "storefront")
        XCTAssertEqual(try page("Referer: http://storefront.local:8491/cart\r\n", port: 8491), "storefront")
        // Nobody's: null, another site, a name that isn't one of these, and everything that only looks like one.
        for origin in ["null", "http://attacker.test", "http://attacker.test:8080", "http://notes.local", "https://storefront.local", "http://storefront.local/",
                       "http://storefront.local:8491", "http://storefront.local:80", "http://storefront.local.attacker.test", "http://storefront.localx",
                       "http://xstorefront.local", "http://Storefront.local", "http://storefront.local@attacker.test", "storefront.local", "http://storefront", "",
                       "http://storefront.local http://attacker.test", "http://attacker.test, http://storefront.local"] {
            XCTAssertNil(try page("Origin: \(origin)\r\n"), origin)
        }
        XCTAssertNil(try page("Origin: http://storefront.local\r\n", port: 8491))                                  // the port is part of it
        XCTAssertNil(try page("Origin: http://storefront.local:8491\r\n"))
        for referer in ["http://attacker.test/", "http://attacker.test/http://storefront.local/", "http://storefront.local", "http://storefront.local.attacker.test/",
                        "http://storefront.local:8491/", "http://storefront.local@attacker.test/", "https://storefront.local/", "http://notes.local/", "//storefront.local/", ""] {
            XCTAssertNil(try page("Referer: \(referer)\r\n"), referer)
        }
        // An Origin that is somebody else's is not mended by a Referer; and two of either header are nobody's.
        XCTAssertNil(try page("Origin: http://attacker.test\r\nReferer: http://storefront.local/\r\n"))
        XCTAssertNil(try page("Origin: null\r\nReferer: http://storefront.local/\r\n"))
        XCTAssertNil(try page("Origin: http://storefront.local\r\nOrigin: http://attacker.test\r\n"))
        XCTAssertNil(try page("Origin: http://storefront.local\r\nOrigin: http://storefront.local\r\n"))
        XCTAssertNil(try page("Referer: http://storefront.local/\r\nReferer: http://attacker.test/\r\n"))
        // Neither header: typed into the address bar, or sent by something that isn't a page.
        XCTAssertNil(try page(""))
        XCTAssertNil(try page("X-Origin: http://storefront.local\r\nX-Forwarded-Host: storefront.local\r\n"))
        // Only among the names it is asked about: the same project's.
        XCTAssertNil(Lan.page(of: try XCTUnwrap(ProxyHead(Data("GET / HTTP/1.1\r\nHost: a.local\r\nOrigin: http://storefront.local\r\n\r\n".utf8))), port: 80, names: ["notes"]))
        XCTAssertNil(Lan.page(of: try XCTUnwrap(ProxyHead(Data("GET / HTTP/1.1\r\nHost: a.local\r\nOrigin: http://storefront.local\r\n\r\n".utf8))), port: 80, names: []))
    }

    /// A folder of its own for one test's password file.
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-test-\(Lan.token(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func mode(_ file: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }

    func testThePasswordFile() throws {
        let file = try scratch().appendingPathComponent("support/network-passwords")
        // No file: nobody has a password. The first one makes it, for this account's eyes only.
        XCTAssertEqual(Passwords.read("/Users/sam/code/storefront", in: file), .none)
        XCTAssertTrue(Passwords.store("/Users/sam/code/storefront", "k7mqx2hw", in: file))
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(Passwords.read("/Users/sam/code/storefront", in: file), .password("k7mqx2hw"))
        XCTAssertEqual(Passwords.read("/Users/sam/code/notes", in: file), .none)                  // one per project
        // More of them, a changed one, a removed one.
        XCTAssertTrue(Passwords.store("/Users/sam/code/notes", "pässwörd ✓ two", in: file))
        XCTAssertTrue(Passwords.store("/Users/sam/code/storefront", "another-one", in: file))
        XCTAssertEqual(Passwords.load(file), ["/Users/sam/code/storefront": "another-one", "/Users/sam/code/notes": "pässwörd ✓ two"])
        XCTAssertTrue(Passwords.store("/Users/sam/code/storefront", nil, in: file))
        XCTAssertEqual(Passwords.read("/Users/sam/code/storefront", in: file), .none)
        XCTAssertEqual(Passwords.read("/Users/sam/code/notes", in: file), .password("pässwörd ✓ two"))
        XCTAssertTrue(Passwords.store("/Users/sam/code/storefront", nil, in: file))                // removing what isn't there is fine
        // Replaced in one step: a new file put in the old one's place (another inode), 0600 whatever the old one was,
        // nothing left beside it, and a link somebody put where the new file is written isn't followed.
        chmod(file.path, 0o644)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        let elsewhere = file.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try Data("untouched".utf8).write(to: elsewhere)
        XCTAssertEqual(symlink(elsewhere.path, file.path + ".new"), 0)
        XCTAssertTrue(Passwords.store("/Users/sam/code/blog", "k7mqx2hw", in: file))
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".new"))
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "untouched")
        XCTAssertEqual(Passwords.load(file)?.count, 2)
    }

    @MainActor
    func testAPasswordThatCantBeReadIsNotNoPassword() throws {
        let folder = try scratch()
        let file = folder.appendingPathComponent("network-passwords")
        let key = "/Users/sam/code/storefront"
        // Whatever is wrong with the file, the answer is "can't be read", never "has none".
        for (what, make) in [("not JSON", { try Data("{\"/Users/sam".utf8).write(to: file) }), ("empty", { try Data().write(to: file) }),
                             ("JSON of another shape", { try Data("[\"k7mqx2hw\"]".utf8).write(to: file) }),
                             ("a password that isn't text", { try Data("{\"/Users/sam/code/storefront\": 12345678}".utf8).write(to: file) }),
                             ("a folder", { try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false) }),
                             ("a link to a good file", {
                                 XCTAssertTrue(Passwords.store(key, "k7mqx2hw", in: folder.appendingPathComponent("good")))
                                 XCTAssertEqual(symlink(folder.appendingPathComponent("good").path, file.path), 0)
                             })] as [(String, () throws -> Void)] {
            try? FileManager.default.removeItem(at: file)
            try make()
            XCTAssertNil(Passwords.load(file), what)
            XCTAssertEqual(Passwords.read(key, in: file), .unreadable, what)
            XCTAssertEqual(Passwords.read("/Users/sam/code/notes", in: file), .unreadable, what)
        }
        // And the rule that follows from it: a share starts with its password, or with none only when the owner
        // has just said so, or not at all. "Can't be read" never opens it, whatever else is true.
        let cant = "The saved password for storefront.local can't be read. Set a new password to put it on the network."
        XCTAssertEqual(Monitor.gate(.unreadable, open: false, name: "storefront").problem, cant)
        XCTAssertEqual(Monitor.gate(.unreadable, open: true, name: "storefront").problem, cant)
        XCTAssertNil(Monitor.gate(.unreadable, open: true, name: "storefront").password)
        XCTAssertEqual(Monitor.gate(.none, open: false, name: "storefront").problem, "Choose a password first, or share it without one.")
        XCTAssertTrue(Monitor.gate(.none, open: true, name: "storefront") == (nil, nil))
        XCTAssertTrue(Monitor.gate(.password("k7mqx2hw"), open: false, name: "storefront") == ("k7mqx2hw", nil))
        XCTAssertTrue(Monitor.gate(.password("k7mqx2hw"), open: true, name: "storefront") == ("k7mqx2hw", nil))      // a password that is there is never dropped by a flag
        // The owner sets a new one: that is written over the file that couldn't be read, and reads back.
        try? FileManager.default.removeItem(at: file)
        try Data("garbage".utf8).write(to: file)
        XCTAssertTrue(Passwords.store(key, "a-new-one-9", in: file))
        XCTAssertEqual(Passwords.read(key, in: file), .password("a-new-one-9"))
        // What couldn't be read isn't thrown away: it is beside the new file, as it was, in case it can be mended.
        let aside = URL(fileURLWithPath: file.path + ".unreadable")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "garbage")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)).intersection(["network-passwords", "network-passwords.unreadable", "network-passwords.new"]),
                       ["network-passwords", "network-passwords.unreadable"])
        // A file that reads fine is never put aside: the next password goes into it, and the one set aside before stays as it is.
        XCTAssertTrue(Passwords.store("/Users/sam/code/notes", "another-one", in: file))
        XCTAssertEqual(Passwords.load(file), [key: "a-new-one-9", "/Users/sam/code/notes": "another-one"])
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "garbage")
        // Something that isn't a file at all in its place (a folder) is put aside the same way, and a password can be set again.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: aside)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertTrue(Passwords.store(key, "a-new-one-9", in: file))
        XCTAssertEqual(Passwords.read(key, in: file), .password("a-new-one-9"))
        XCTAssertEqual(mode(file), 0o600)

        // The app itself, with a file that can't be read: the project isn't put on the network, its panel says it
        // has no saved password (so it offers a new one), and "show" has nothing to show.
        try Data("garbage".utf8).write(to: file)
        let kept = (Passwords.inMemory, Passwords.file)
        Passwords.inMemory = false
        Passwords.file = file
        defer { (Passwords.inMemory, Passwords.file) = kept }
        let (m, _, rows) = sharedFixture()
        m.stopAllSharing()
        let main = rows.first { $0.port == 3000 }!
        XCTAssertFalse(m.hasNetworkPassword(Names.key(main)))
        XCTAssertNil(m.networkPassword(Names.key(main)))
        if LAN.current() != nil {
            XCTAssertEqual(m.shareOnNetwork(main), "The saved password for \(m.networkName(main) ?? "").local can't be read. Set a new password to put it on the network.")
            XCTAssertTrue(m.lanShares.isEmpty)
        }
        // On the network with a password, then the file goes bad and the project is renamed there: it comes off
        // the network with that said, rather than going on under the new name with no password.
        m.useFixture(rows, shared: Names.key(main))
        XCTAssertEqual(m.lanShares.count, 1)
        let problem = m.renameOnNetwork(main, to: "shop")
        XCTAssertEqual(problem?.hasSuffix("can't be read. Set a new password to put it on the network."), true)
        XCTAssertTrue(m.lanShares.isEmpty)
        XCTAssertEqual(m.notices.last?.text, problem)
        _ = m.renameOnNetwork(main, to: "")
    }

    func testTheKeychainIsEmptiedOnceAndNeverAsked() throws {
        let file = try scratch().appendingPathComponent("network-passwords")
        // What 1.4.0 left in the Keychain: one item this build can read, one that would need the owner's login
        // password (read: nil, because asking is forbidden), and one for a project that has a newer password in the file.
        var items: [String: String?] = ["/Users/sam/code/storefront": "k7mqx2hw", "/Users/sam/code/notes": nil, "/Users/sam/code/blog": "old-one-77"]
        var asked: [String] = []
        let keychain = Passwords.Keychain(accounts: { items.keys.sorted() }, read: { asked.append($0); return items[$0] ?? nil }, delete: { items[$0] = nil })
        XCTAssertTrue(Passwords.store("/Users/sam/code/blog", "newer-one-88", in: file))
        XCTAssertEqual(Passwords.move(from: keychain, into: file), 2)
        XCTAssertEqual(asked, ["/Users/sam/code/blog", "/Users/sam/code/notes", "/Users/sam/code/storefront"])
        // The readable one is in the file and out of the Keychain.
        XCTAssertEqual(Passwords.read("/Users/sam/code/storefront", in: file), .password("k7mqx2hw"))
        // The one that would have needed a prompt is left where it is, and its project has no saved password.
        XCTAssertEqual(Passwords.read("/Users/sam/code/notes", in: file), .none)
        XCTAssertEqual(Array(items.keys), ["/Users/sam/code/notes"])
        // The newer password in the file won.
        XCTAssertEqual(Passwords.read("/Users/sam/code/blog", in: file), .password("newer-one-88"))
        XCTAssertEqual(mode(file), 0o600)
        // A file that can't be read: nothing is moved and nothing is deleted from the Keychain.
        items = ["/Users/sam/code/storefront": "k7mqx2hw"]
        try Data("garbage".utf8).write(to: file)
        XCTAssertEqual(Passwords.move(from: keychain, into: file), 0)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "garbage")
        // A file that can't be written (there is none yet, and its folder takes no new files): the item stays in the Keychain.
        let locked = try scratch().appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o555])
        defer { chmod(locked.path, 0o755) }
        XCTAssertEqual(Passwords.load(locked.appendingPathComponent("network-passwords")), [:])
        XCTAssertEqual(Passwords.move(from: keychain, into: locked.appendingPathComponent("network-passwords")), 0)
        XCTAssertEqual(items.count, 1, "not deleted from the Keychain before it is safely in the file")
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

    func testAPageCallsItsProjectsOtherServer() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        let here = "127.0.0.1", loopback = LAN.Network(interface: "lo0", address: here, router: nil), password = "k7mqx2hw"
        // One project with a front end and a back end on the network, one password; and another project beside them.
        let port = try XCTUnwrap(net.start(name: "storefront", project: "/code/storefront", server: project.server, password: password, on: loopback, port: 0))
        XCTAssertEqual(net.start(name: "storefront-8000", project: "/code/storefront", server: project.server, password: password, on: loopback, port: port), port)
        XCTAssertEqual(net.start(name: "notes", project: "/code/notes", server: project.server, password: password, on: loopback, port: port), port)
        func request(_ method: String, _ name: String, _ path: String, _ extra: String = "") throws -> String {
            try ask(here, port, "\(method) \(path) HTTP/1.1\r\nHost: \(name).local:\(port)\r\n\(extra)\r\n") ?? ""
        }
        // What a page on the front end's name sends when it calls the back end: first the browser's own question, with no cookie.
        let preflight = "Origin: http://storefront.local:\(port)\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type\r\n"
        // Before anybody has signed in: the sign-in page for all of it, and nothing reaches the project.
        XCTAssertTrue(try request("OPTIONS", "storefront-8000", "/api/items", preflight).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items").hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(project.seen.isEmpty)
        // A session from another address is nobody's here, whatever a header says about where the request comes from.
        _ = net.withVisitors { $0.signIn(to: "storefront", project: "/code/storefront", from: "10.0.0.5", now: Date()) }
        XCTAssertEqual(net.devices(project: "/code/storefront"), 1)
        for forged in ["", "X-Forwarded-For: 10.0.0.5\r\n", "Forwarded: for=10.0.0.5\r\n", "X-Real-IP: 10.0.0.5\r\n", "X-Forwarded-For: 10.0.0.5\r\nX-Real-IP: 10.0.0.5\r\n"] {
            XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", "Origin: http://storefront.local:\(port)\r\n" + forged).hasPrefix("HTTP/1.1 401 "), forged)
        }
        XCTAssertTrue(project.seen.isEmpty)
        // The visitor signs in, once, on the front end's name.
        let own = "Origin: http://storefront.local:\(port)\r\nContent-Type: application/json\r\n"
        let c = json(try ask(here, port, "POST /__harbor/challenge HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\(own)Content-Length: 2\r\n\r\n{}"))
        let nonce = try XCTUnwrap(c["nonce"] as? String), body = "{\"nonce\":\"\(nonce)\",\"proof\":\"\(answer(password, salt: try XCTUnwrap(c["salt"] as? String), name: "storefront", nonce: nonce))\"}"
        let entered = try ask(here, port, "POST /__harbor/enter HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\(own)Content-Length: \(body.utf8.count)\r\n\r\n\(body)") ?? ""
        XCTAssertTrue(entered.hasPrefix("HTTP/1.1 200 "))
        let cookie = "Cookie: " + (try XCTUnwrap(entered.components(separatedBy: "\r\n").first { $0.hasPrefix("Set-Cookie: ") }?.dropFirst(12).prefix { $0 != ";" })) + "\r\n"
        XCTAssertEqual(net.devices(project: "/code/storefront"), 2)
        // Now its address is known for the project, for the project's own pages: the back end answers the browser's
        // question and the call, with no cookie. So does an image or a script the page loads from it (no Origin, the
        // page's Referer), a WebSocket (Origin), and a page of the back end itself that got in this way.
        let front = "Origin: http://storefront.local:\(port)\r\n"
        XCTAssertTrue(try request("OPTIONS", "storefront-8000", "/api/items", preflight).hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("POST", "storefront-8000", "/api/items", front + "Content-Type: application/json\r\nContent-Length: 0\r\n").hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("GET", "storefront-8000", "/logo.png", "Referer: http://storefront.local:\(port)/cart\r\n").hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("GET", "storefront-8000", "/app.js", "Origin: http://storefront-8000.local:\(port)\r\n").hasSuffix("\r\n\r\nok"))
        XCTAssertEqual(project.seen.count, 4)
        // Any other page open on that device comes from the same address, and gets nothing: another site (its call, and
        // the browser's question before it), another project's page, a page with no origin, a link followed from
        // elsewhere, and a request that says nothing about where it comes from (the name typed into the address bar).
        for foreign in ["Origin: http://attacker.test:8080\r\n", "Origin: http://attacker.test:8080\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Headers: content-type\r\n",
                        "Origin: http://notes.local:\(port)\r\n", "Origin: null\r\n", "Origin: null\r\nReferer: http://storefront.local:\(port)/\r\n",
                        "Origin: http://storefront.local\r\n", "Origin: http://storefront.local:\(port).attacker.test\r\n", "Origin: https://storefront.local:\(port)\r\n",
                        "Referer: http://attacker.test:8080/\r\n", "Referer: http://attacker.test/http://storefront.local:\(port)/\r\n",
                        "Origin: http://attacker.test\r\nReferer: http://storefront.local:\(port)/\r\n", front + "Origin: http://attacker.test\r\n", ""] {
            for method in ["GET", "OPTIONS", "POST"] {
                XCTAssertTrue(try request(method, "storefront-8000", "/api/items", foreign + (method == "POST" ? "Content-Length: 0\r\n" : "")).hasPrefix("HTTP/1.1 401 "), "\(method) \(foreign)")
            }
        }
        XCTAssertEqual(project.seen.count, 4)
        // The front end has no session on another name behind it, so it opens with its cookie only; and another
        // project stays shut, whatever the request says and wherever it comes from.
        XCTAssertTrue(try request("GET", "storefront", "/", front).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("GET", "notes", "/", front).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("GET", "notes", "/", "Origin: http://notes.local:\(port)\r\n").hasPrefix("HTTP/1.1 401 "))
        XCTAssertEqual(project.seen.count, 4)

        // In use. The visitor leaves; twenty minutes on, whoever has that address gets nothing from it, however the
        // request is dressed. Requests that got in this way in between kept nothing alive.
        let start = Date()
        var minutes = 10.0
        net.clock = { start.addingTimeInterval(minutes * 60) }
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        minutes = 14.9
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        minutes = 20
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("OPTIONS", "storefront-8000", "/api/items", preflight).hasPrefix("HTTP/1.1 401 "))
        // The session is as good as ever. Its cookie comes from that address again (the page is reloaded): in use again,
        // for fifteen minutes from then. The cookie never reaches the project, here or there.
        XCTAssertTrue(try request("GET", "storefront", "/", cookie).hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        XCTAssertFalse(project.seen.contains { $0.contains(Lan.cookie) })
        minutes = 34.9
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        minutes = 35.1
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))
        // The cookie on the back end's name is no session there (it is the front end's), and revives nothing.
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", cookie).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front + cookie).hasPrefix("HTTP/1.1 401 "))
        // A connection that came with the cookie and stays open (the page's hot-reload socket) keeps it in use for as
        // long as it is open, hours if need be; a socket that got in through the back end's name keeps nothing.
        let reload = try begin(here, port, "GET /hmr HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\(cookie)Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        XCTAssertTrue(reload.head.hasPrefix("HTTP/1.1 101 "), reload.head)
        let stream = try begin(here, port, "GET /live HTTP/1.1\r\nHost: storefront-8000.local:\(port)\r\n\(front)Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        defer { close(stream.fd) }
        XCTAssertTrue(stream.head.hasPrefix("HTTP/1.1 101 "), stream.head)
        minutes = 200
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        close(reload.fd)
        var shut = false
        for _ in 0..<40 where !shut {
            shut = try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 ")
            if !shut { Thread.sleep(forTimeInterval: 0.05) }
        }
        XCTAssertTrue(shut, "with its socket closed the session is no longer in use, and the back end's own socket doesn't stand in for it")
        XCTAssertFalse(Self.ended(stream.fd, within: 0.2))                               // what is open stays open; nothing new gets in

        // Something is open to the back end that way (a stream, a socket). The owner changes the password: every name of
        // the project gets it (Monitor does that), the sessions are gone, and what they let in is cut on the other name too.
        XCTAssertTrue(try request("GET", "storefront", "/", cookie).hasSuffix("\r\n\r\nok"))
        let socket = try begin(here, port, "GET /live HTTP/1.1\r\nHost: storefront-8000.local:\(port)\r\n\(front)Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        defer { close(socket.fd) }
        XCTAssertTrue(socket.head.hasPrefix("HTTP/1.1 101 "), socket.head)
        net.setPassword("another-one", for: "storefront")
        XCTAssertTrue(Self.ended(socket.fd, within: 1), "what the front end's session let in on the back end is cut with it")
        XCTAssertTrue(Self.ended(stream.fd, within: 1))
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("GET", "storefront", "/", cookie).hasPrefix("HTTP/1.1 401 "))
        XCTAssertEqual(net.devices(project: "/code/storefront"), 0)
        // Signed in again; then the front end goes off the network: its session goes, and the back end is shut again.
        _ = net.withVisitors { $0.signIn(to: "storefront", project: "/code/storefront", from: here, now: net.clock()) }
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        net.stop("storefront")
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))
        // A name that is no longer shared is nobody's page either, with a session or without.
        _ = net.withVisitors { $0.signIn(to: "storefront", project: "/code/storefront", from: here, now: net.clock()) }
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))
        // With no password there is no gate and nothing to remember: every shared server is open, as before.
        net.setPassword(nil, for: "storefront-8000")
        XCTAssertTrue(try request("GET", "storefront-8000", "/api/items").hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("GET", "notes", "/").hasPrefix("HTTP/1.1 401 "))
    }

    /// A visitor's cookie is a session only from the address it was signed in from. From any
    /// other address the visitor gets the sign-in page, like anyone without a cookie, and
    /// signs in again; a cookie read off the network is no use from the reader's own address.
    func testACookieIsGoodOnlyFromItsOwnAddress() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        let here = "127.0.0.1", loopback = LAN.Network(interface: "lo0", address: here, router: nil), password = "k7mqx2hw", folder = "/code/storefront"
        let port = try XCTUnwrap(net.start(name: "storefront", project: folder, server: project.server, password: password, on: loopback, port: 0))
        XCTAssertEqual(net.start(name: "storefront-8000", project: folder, server: project.server, password: password, on: loopback, port: port), port)
        func request(_ name: String, _ path: String, _ extra: String = "") throws -> String {
            try ask(here, port, "GET \(path) HTTP/1.1\r\nHost: \(name).local:\(port)\r\n\(extra)\r\n") ?? ""
        }
        func socket(_ name: String, _ extra: String) throws -> (fd: Int32, head: String) {
            try begin(here, port, "GET /live HTTP/1.1\r\nHost: \(name).local:\(port)\r\n\(extra)Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
        }
        /// Signs in on the front end's name over the wire, as its sign-in page does, with whatever cookie the browser holds. The new cookie, as a header.
        func signIn(holding cookie: String = "") throws -> String {
            let own = "Origin: http://storefront.local:\(port)\r\nContent-Type: application/json\r\n" + cookie
            let c = json(try ask(here, port, "POST /__harbor/challenge HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\(own)Content-Length: 2\r\n\r\n{}"))
            let nonce = try XCTUnwrap(c["nonce"] as? String), body = "{\"nonce\":\"\(nonce)\",\"proof\":\"\(answer(password, salt: try XCTUnwrap(c["salt"] as? String), name: "storefront", nonce: nonce))\"}"
            let entered = try ask(here, port, "POST /__harbor/enter HTTP/1.1\r\nHost: storefront.local:\(port)\r\n\(own)Content-Length: \(body.utf8.count)\r\n\r\n\(body)") ?? ""
            XCTAssertTrue(entered.hasPrefix("HTTP/1.1 200 "), entered)
            return "Cookie: " + (try XCTUnwrap(entered.components(separatedBy: "\r\n").first { $0.hasPrefix("Set-Cookie: ") }?.dropFirst(12).prefix { $0 != ";" })) + "\r\n"
        }
        /// A page without what changes on every load (its nonces).
        func plain(_ page: String) -> String { page.replacingOccurrences(of: "[0-9a-f]{32}", with: "#", options: .regularExpression) }
        let front = "Origin: http://storefront.local:\(port)\r\n"

        // A session that was signed in from another address (the visitor's device, before its address changed; or the
        // device somebody read the cookie from). Its cookie arrives from here.
        let token = net.withVisitors { $0.signIn(to: "storefront", project: folder, from: "10.0.0.5", now: Date()) }
        let away = "Cookie: \(Lan.cookie)=\(token)\r\n"
        XCTAssertTrue(net.withVisitors { $0.isSignedIn(token, to: "storefront", from: "10.0.0.5", now: Date()) })
        // The sign-in page, the very one a visitor with no cookie gets: no error on it, and nothing reaches the project.
        let page = try request("storefront", "/", away)
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 401 "))
        XCTAssertEqual(plain(page), plain(try request("storefront", "/")))
        XCTAssertTrue(page.contains("id=\"password\""))
        XCTAssertTrue(try socket("storefront", away).head.hasPrefix("HTTP/1.1 401 "))                       // a WebSocket is a request like any other
        XCTAssertTrue(try request("storefront-8000", "/api/items", front).hasPrefix("HTTP/1.1 401 "))       // and it opens no other name from here
        XCTAssertTrue(try request("storefront-8000", "/api/items", front + away).hasPrefix("HTTP/1.1 401 "))
        // It is not a wrong try, however often it comes: nothing is counted, nobody waits.
        for _ in 0..<(Visitors.triesPerAddress + 3) { XCTAssertTrue(try request("storefront", "/", away).hasPrefix("HTTP/1.1 401 ")) }
        XCTAssertEqual(net.withVisitors { $0.counts.addresses }, 0)
        XCTAssertNil(net.withVisitors { $0.wait(address: here, name: "storefront", now: Date()) })
        XCTAssertTrue(project.seen.isEmpty)
        XCTAssertEqual(net.devices(project: folder), 1)

        // The visitor signs in again from the new address, the old cookie still in the browser. A new session, for
        // this address; the old one is over, so the device is counted once and the old cookie is good nowhere.
        let cookie = try signIn(holding: away)
        XCTAssertNotEqual(cookie, away)
        XCTAssertEqual(net.devices(project: folder), 1)
        XCTAssertFalse(net.withVisitors { $0.isSignedIn(token, to: "storefront", from: "10.0.0.5", now: Date()) })
        XCTAssertTrue(try request("storefront", "/", away).hasPrefix("HTTP/1.1 401 "))
        // Its cookie from its own address passes, and is not shown to the project.
        XCTAssertTrue(try request("storefront", "/", cookie).hasSuffix("\r\n\r\nok"))
        XCTAssertFalse(project.seen.contains { $0.contains(Lan.cookie) })
        // The way into the project's other names is the new session's address's, and nobody else's.
        XCTAssertTrue(try request("storefront-8000", "/api/items", front).hasSuffix("\r\n\r\nok"))
        XCTAssertNil(net.withVisitors { $0.sibling(of: "storefront-8000", project: folder, address: "10.0.0.5", now: Date()) })
        XCTAssertNotNil(net.withVisitors { $0.sibling(of: "storefront-8000", project: folder, address: here, now: Date()) })

        // What a session let in ends with it, and only that. This browser has a socket open on the front end (its
        // cookie) and one on the back end (through its session). Another browser on the same device signs in too
        // (no cookie to replace) and has a socket of its own.
        let mine = try socket("storefront", cookie), api = try socket("storefront-8000", front)
        defer { close(mine.fd); close(api.fd) }
        XCTAssertTrue(mine.head.hasPrefix("HTTP/1.1 101 ") && api.head.hasPrefix("HTTP/1.1 101 "))
        let second = try signIn()
        let theirs = try socket("storefront", second)
        defer { close(theirs.fd) }
        XCTAssertTrue(theirs.head.hasPrefix("HTTP/1.1 101 "))
        XCTAssertFalse(Self.ended(mine.fd, within: 0.2) || Self.ended(api.fd, within: 0.1))                   // a sign-in that replaces nothing cuts nothing
        // The first browser signs in once more, holding its cookie: that session is replaced, and both its sockets are cut.
        let again = try signIn(holding: cookie)
        XCTAssertTrue(Self.ended(mine.fd, within: 1), "the replaced session's own socket")
        XCTAssertTrue(Self.ended(api.fd, within: 1), "and what it let in on the back end")
        XCTAssertFalse(Self.ended(theirs.fd, within: 0.3), "the other browser's session is its own")
        XCTAssertTrue(try request("storefront", "/", cookie).hasPrefix("HTTP/1.1 401 "))
        XCTAssertTrue(try request("storefront", "/", again).hasSuffix("\r\n\r\nok"))
        XCTAssertTrue(try request("storefront", "/", second).hasSuffix("\r\n\r\nok"))
        XCTAssertEqual(net.devices(project: folder), 1)
        // And a session that ends the usual way (the password changes) still takes what it let in with it.
        let later = try socket("storefront-8000", front)
        defer { close(later.fd) }
        XCTAssertTrue(later.head.hasPrefix("HTTP/1.1 101 "))
        net.setPassword("another-one", for: "storefront")
        XCTAssertTrue(Self.ended(theirs.fd, within: 1) && Self.ended(later.fd, within: 1))
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

    // MARK: Port 80 and the door

    /// launchctl as `Door.aside` sees it, for a test: what is loaded, what was asked, what refuses.
    private final class Launchd {
        var loaded: Bool
        var calls: [String] = []
        var bootstrapsRefused = 0
        var reloadsBy = 0              // somebody else loads the door again this many times, right after it was unloaded
        init(loaded: Bool = true) { self.loaded = loaded }
        func run(_ args: [String]) -> Bool {
            calls.append(args[0])
            switch args[0] {
            case "print": return loaded
            case "bootout":
                loaded = reloadsBy > 0
                reloadsBy = max(0, reloadsBy - 1)
                return true
            case "bootstrap":
                if bootstrapsRefused > 0 { bootstrapsRefused -= 1; return false }
                loaded = true
                return true
            default: return false
            }
        }
    }

    func testTheDoorStepsAsideWhileThePortIsBound() throws {
        let plist = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-test-door-\(Lan.token(4)).plist")
        try Data("x".utf8).write(to: plist)
        defer { try? FileManager.default.removeItem(at: plist) }
        func aside(_ d: Launchd, plist: URL = plist, answers: Bool = false, bind: @escaping () -> Bool) -> (opening: Door.Opening, doorBack: Bool) {
            Door.aside(label: "local.harbor.test.door", plist: plist, bind: { d.calls.append("bind"); return bind() }, answers: { d.calls.append("answers"); return answers },
                       run: d.run, pause: { d.calls.append("pause") })
        }
        // While the door is loaded the port can't be bound (that is the whole reason), so: door out, bind, door back, in that order.
        var d = Launchd()
        var r = aside(d) { !d.loaded }
        XCTAssertEqual(d.calls, ["print", "bootout", "bind", "bootstrap"])
        XCTAssertTrue(r.opening == .open && r.doorBack && d.loaded)
        // No door loaded: nothing to unload, and the one on file is loaded afterwards.
        d = Launchd(loaded: false)
        r = aside(d) { !d.loaded }
        XCTAssertEqual(d.calls, ["print", "bind", "bootstrap"])
        XCTAssertTrue(r.opening == .open && r.doorBack)
        // No door at all (never installed): just the bind.
        d = Launchd(loaded: false)
        r = aside(d, plist: plist.appendingPathExtension("missing")) { true }
        XCTAssertEqual(d.calls, ["print", "bind"])
        XCTAssertTrue(r.opening == .open && r.doorBack && !d.loaded)
        // Somebody loads the door again in between (headroom's launcher, harbor's own check): out again, and then it works.
        d = Launchd()
        d.reloadsBy = 2
        r = aside(d) { !d.loaded }
        XCTAssertEqual(d.calls, ["print", "bootout", "bind", "pause", "print", "bootout", "bind", "pause", "print", "bootout", "bind", "bootstrap"])
        XCTAssertTrue(r.opening == .open && r.doorBack && d.loaded)
        // The door's bootstrap is refused a few times (launchd still letting go): tried again, as install does.
        d = Launchd()
        d.bootstrapsRefused = 3
        r = aside(d) { !d.loaded }
        XCTAssertTrue(r.opening == .open && r.doorBack && d.loaded)
        XCTAssertEqual(d.calls.filter { $0 == "bootstrap" }.count, 4)
        // Another program really has the port: the bind fails with the door out. The door is back before anything is said.
        d = Launchd()
        r = aside(d, answers: true) { false }
        XCTAssertEqual(r.opening, .taken)
        XCTAssertTrue(r.doorBack && d.loaded, "the door is back")
        XCTAssertEqual(d.calls.filter { $0 == "bind" }.count, 5)
        XCTAssertEqual(Array(d.calls.suffix(2)), ["answers", "bootstrap"])
        XCTAssertFalse(d.calls.contains("bootstrap") && d.calls.firstIndex(of: "bootstrap")! < d.calls.lastIndex(of: "bind")!, "never loaded again before the last try")
        // Nobody answers there and still it can't be bound (connections just closed keep it a while): said as it is, door back.
        d = Launchd()
        r = aside(d, answers: false) { false }
        XCTAssertEqual(r.opening, .busy)
        XCTAssertTrue(r.doorBack && d.loaded)
        // The door can't be loaded again at all: the listener is still open, and the owner is told (doorBack false).
        d = Launchd()
        d.bootstrapsRefused = 99
        r = aside(d) { !d.loaded }
        XCTAssertTrue(r.opening == .open && !r.doorBack && !d.loaded)
        XCTAssertEqual(d.calls.filter { $0 == "bootstrap" }.count, 15)

        // What the owner reads. Never "another program" for harbor's own door.
        XCTAssertEqual(Monitor.portProblem(80, .taken, holder: nil, ownDoor: false), "Port 80 on this Mac is used by another program, so nothing can go on the network.")
        XCTAssertEqual(Monitor.portProblem(80, .taken, holder: "nginx", ownDoor: false), "Port 80 on this Mac is used by nginx, so nothing can go on the network.")
        XCTAssertEqual(Monitor.portProblem(80, .busy, holder: nil, ownDoor: false), "Port 80 on this Mac isn't free yet. Try again in half a minute.")
        XCTAssertTrue(Monitor.portProblem(80, .taken, holder: "nginx", ownDoor: true).hasPrefix("Port 80 is harbor's own door's"))
    }

    func testOnlyTheFirstShareMovesTheDoor() throws {
        let project = try XCTUnwrap(Project())
        defer { project.stop() }
        let net = OnNetwork(announces: false)
        defer { net.stopAll() }
        var asides = 0, refuse: Door.Opening?, back = true
        net.aside = { bind, _ in
            asides += 1
            if let refuse { return (refuse, back) }
            return (bind() ? .open : .busy, back)
        }
        let network = LAN.Network(interface: "en0", address: "192.0.2.24", router: nil)
        // A port under 1024 stands in for port 80: there the door is in the way, and is asked aside. Once.
        var port: UInt16 = 0
        for wanted in stride(from: UInt16(1023), to: 1000, by: -1) where port == 0 {
            asides = 0
            port = net.begin(name: "storefront", server: project.server, password: nil, on: network, port: wanted).port ?? 0
        }
        if port == 0 { throw XCTSkip("no free port under 1024 to stand in for port 80") }
        XCTAssertEqual(asides, 1)
        XCTAssertTrue(net.holdsIPv6, "the same port on IPv6, bound in the same breath")
        // A second and a third project use the listener that is there: the door isn't touched again.
        XCTAssertEqual(net.begin(name: "notes", server: project.server, password: nil, on: network, port: port).port, port)
        XCTAssertEqual(net.begin(name: "blog", server: project.server, password: "k7mqx2hw", on: network, port: port).port, port)
        XCTAssertEqual(asides, 1)
        XCTAssertEqual(Set(net.names), ["storefront", "notes", "blog"])
        // One stops, the others stay; the last one closes the listener, and the next first one asks the door aside again.
        net.stop("storefront")
        XCTAssertEqual(net.port, port)
        net.stop("notes"); net.stop("blog")
        XCTAssertEqual(net.port, 0)
        XCTAssertNotNil(net.begin(name: "storefront", server: project.server, password: nil, on: network, port: port).port)
        XCTAssertEqual(asides, 2)
        net.stopAll()
        // The port couldn't be had: nothing is shared, and what came of the door is passed on as it is.
        refuse = .taken; back = false
        let begun = net.begin(name: "storefront", server: project.server, password: nil, on: network, port: port)
        XCTAssertNil(begun.port)
        XCTAssertEqual(begun.opening, .taken)
        XCTAssertFalse(begun.doorBack)
        XCTAssertTrue(net.names.isEmpty)
        XCTAssertEqual(net.port, 0)
        // A high port (debug runs, tests) has no door in the way: never asked.
        refuse = nil; asides = 0
        XCTAssertNotNil(net.begin(name: "storefront", server: project.server, password: nil, on: LAN.Network(interface: "lo0", address: "127.0.0.1", router: nil), port: 0).port)
        XCTAssertEqual(asides, 0)
    }

    func testAClosedConnectionLeavesNothingOnThePort() throws {
        // What the door does with every connection: after it, the port can be bound again at once, even by a
        // socket that tolerates nothing (no SO_REUSEADDR). A plain close keeps it for half a minute.
        func serveOnce(close finish: (Int32) -> Void) throws -> Bool {
            let listener = try XCTUnwrap(grab("127.0.0.1", 0, options: []))
            XCTAssertEqual(listen(listener, 4), 0)
            let port = Sock.port(of: listener)
            let client = try XCTUnwrap(Sock.connect(["127.0.0.1"], port: port, within: 2))
            let served = accept(listener, nil, nil)
            XCTAssertGreaterThanOrEqual(served, 0)
            Sock.send(served, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            // The other side reads the reply to its end and closes, as a browser does.
            let reader = expectation(description: "the client has read it all")
            Thread.detachNewThread {
                var chunk = [UInt8](repeating: 0, count: 4096), got = 0
                while true { let n = read(client, &chunk, chunk.count); if n > 0 { got += n } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break } else { usleep(2000) } }
                XCTAssertGreaterThan(got, 40)
                close(client)
                reader.fulfill()
            }
            finish(served)
            wait(for: [reader], timeout: 3)
            close(listener)
            guard let again = grab("127.0.0.1", port, options: []) else { return false }
            close(again)
            return true
        }
        XCTAssertTrue(try serveOnce { Sock.closeLeavingNothing($0) }, "free at once")
        XCTAssertFalse(try serveOnce { close($0) }, "a plain close first keeps the port (which is why the door doesn't)")
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
