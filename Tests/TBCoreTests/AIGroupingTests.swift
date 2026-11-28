import XCTest
@testable import TBCore

/// The first pass at groupings by Claude: what is sent, and how the reply is read. Nothing here
/// touches the network.
final class AIGroupingTests: XCTestCase {

    func books() throws -> Engagement {
        var e = Engagement(name: "Summit Storage", periodEnd: "2026-12-31")
        for (name, csv) in [("Ashford", "Account,Debit,Credit\n1000 Cash,100,\n4000 Rental Income,,900\n6100 Insurance,300,\n6200 Advertising,500,\n"),
                            ("Brighton", "Account,Debit,Credit\n1000 Cash,50,\n4000 Rental Income,,75\n6300 Web Hosting,25,\n")] {
            let sheet = RawSheet(name: "s", rows: TBImporter.parseCSV(csv))
            let id = try e.addEntity(named: name)
            _ = try e.importTrialBalance(TBImporter.evaluate(sheet, TBImporter.guess(sheet), sourceName: name).tb, into: id)
        }
        _ = e.setGrouping("802", forAccounts: ["4000"])
        _ = e.setGrouping("807", forAccounts: ["6100"])
        return e
    }

    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: What is sent

    func testAWorkbookBecomesPlainLinesWithNothingLost() {
        let sheet = RawSheet(name: "TB", rows: [["Account", "", "Debit", "", ""], [], ["", "", ""], ["1000 Cash", "", "100.00"], ["a\tb", "two\nlines"]])
        XCTAssertEqual(AIGrouping.lightweight(sheet), "Account\t\tDebit\n1000 Cash\t\t100.00\na b\ttwo lines")
        let file = AIGrouping.ContextFile(name: "PY.xlsx", sheets: [sheet, RawSheet(name: "Notes", rows: [])])
        let text = AIGrouping.lightweight(file)
        XCTAssertTrue(text.hasPrefix("<sheet name=\"TB\">\nAccount"))
        XCTAssertTrue(text.contains("<sheet name=\"Notes\">\n(empty)\n</sheet>"))
        XCTAssertGreaterThan(AIGrouping.estimatedTokens(text), text.count / 4)
    }

    func testTheRequestCarriesTheListTheGroupedAccountsAndTheOnesToGroup() throws {
        let e = try books()
        let ungrouped = e.ungroupedAccounts
        XCTAssertEqual(ungrouped.map(\.id), ["1000", "6200", "6300"])
        let background = AIGrouping.background(for: e, toGroup: ungrouped,
                                               context: [AIGrouping.ContextFile(name: "Prior year.xlsx", sheets: [RawSheet(name: "TB", rows: [["6200 Advertising", "803"]])])])
        XCTAssertTrue(background.contains("Client: Summit Storage"))
        XCTAssertTrue(background.contains("Trial balances: Ashford, Brighton"))
        // Every grouping in the list, by id, subgroups with their parent.
        XCTAssertTrue(background.contains("803\t803\tADVERTISING\t8825 Accounts\tExpense\t\n"), background)
        XCTAssertTrue(background.contains("815-AMORT\t815\tAMORTIZATION\t8825 Accounts\t"))
        for g in e.groupings { XCTAssertTrue(background.contains("\n\(g.id)\t"), g.id) }
        // The accounts already grouped are the examples; the ones being asked about aren't among them.
        XCTAssertTrue(background.contains("4000\tRental Income\t802\n"))
        XCTAssertTrue(background.contains("6100\tInsurance\t807\n"))
        XCTAssertFalse(background.contains("6200\tAdvertising"))
        XCTAssertTrue(background.contains("<context_file name=\"Prior year.xlsx\">\n<sheet name=\"TB\">\n6200 Advertising\t803\n</sheet>\n</context_file>"))

        let question = AIGrouping.question(for: e, accounts: ungrouped)
        XCTAssertTrue(question.contains("account id\taccount number\taccount name\tbalance in Ashford\tbalance in Brighton\n"))
        XCTAssertTrue(question.contains("1000\t1000\tCash\t100.00\t50.00\n"), question)
        XCTAssertTrue(question.contains("6300\t6300\tWeb Hosting\t0.00\t25.00\n"), question)
        XCTAssertTrue(question.hasSuffix("each of the 3 accounts in accounts_to_group, using the account id exactly as given."))
        XCTAssertEqual(AIGrouping.message(for: e, accounts: ungrouped), AIGrouping.background(for: e, toGroup: ungrouped) + "\n" + question)
    }

    func testWithNothingGroupedYetItSaysSo() throws {
        var e = try books()
        _ = e.setGrouping(nil, forAccounts: ["4000", "6100"])
        XCTAssertTrue(AIGrouping.background(for: e, toGroup: e.ungroupedAccounts).contains("<accounts_already_grouped>\n(none yet)\n</accounts_already_grouped>"))
    }

    func testTheRequestBodyIsWhatTheAPIExpects() throws {
        let body = try json(AIGrouping.requestBody(background: "BACK \"quoted\"\n", question: "ASK"))
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual(body["system"] as? String, AIGrouping.system)
        // Nothing the current models reject.
        for key in ["temperature", "top_p", "top_k", "tool_choice", "tools"] { XCTAssertNil(body[key], key) }

        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(config["effort"] as? String, "high")
        let format = try XCTUnwrap(config["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["assignments"])
        let item = try XCTUnwrap(((schema["properties"] as? [String: Any])?["assignments"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(item["required"] as? [String], ["account", "grouping", "confidence", "reason"])
        XCTAssertEqual(Set((item["properties"] as? [String: Any] ?? [:]).keys), ["account", "grouping", "confidence", "reason"])

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["text"] as? String }, ["BACK \"quoted\"\n", "ASK"])
        XCTAssertNil(content[0]["cache_control"])

        // Sent in parts, the background is marked as repeated so it is only charged in full once.
        let reused = try json(AIGrouping.requestBody(background: "BACK", question: "ASK", reused: true))
        let blocks = try XCTUnwrap((reused["messages"] as? [[String: Any]])?[0]["content"] as? [[String: Any]])
        XCTAssertEqual((blocks[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertNil(blocks[1]["cache_control"])
    }

    func testALargeChartIsAskedAboutInParts() {
        let accounts = (1...450).map { Account(number: String(1000 + $0), name: "Account \($0)") }
        let parts = AIGrouping.batches(accounts)
        XCTAssertEqual(parts.map(\.count), [200, 200, 50])
        XCTAssertEqual(parts.flatMap { $0 }.map(\.id), accounts.map(\.id))
        XCTAssertEqual(AIGrouping.batches([]).count, 0)
    }

    // MARK: What comes back

    func testAStreamedReplyIsPutTogether() {
        var stream = AIGrouping.Stream()
        for line in [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":1200}}}"#,
            "",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"not the answer"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"assign"}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ments\":[]}"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
            #"data: {"type":"message_stop"}"#,
            "data: not json",
        ] { stream.feed(line: line) }
        XCTAssertEqual(stream.text, #"{"assignments":[]}"#)
        XCTAssertEqual(stream.stopReason, "end_turn")
        XCTAssertEqual(stream.model, "claude-opus-5-5")
        XCTAssertEqual(stream.inputTokens, 1200)
        XCTAssertEqual(stream.outputTokens, 42)
        XCTAssertNil(stream.error)

        var failed = AIGrouping.Stream()
        failed.feed(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertEqual(failed.error, "Anthropic's service is busy just now. Try again in a minute.")
        var refused = AIGrouping.Stream()
        refused.feed(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#)
        XCTAssertEqual(refused.stopReason, "refusal")
    }

    func testErrorsAreSaidInWordsThatCanBeActedOn() {
        XCTAssertTrue(AIGrouping.explain(status: 401, type: "authentication_error", message: "invalid x-api-key").contains("Settings ▸ AI"))
        XCTAssertTrue(AIGrouping.explain(status: 429, type: "rate_limit_error", message: "slow down").contains("rate limit"))
        XCTAssertTrue(AIGrouping.explain(status: 413, type: "request_too_large", message: "").contains("fewer context files"))
        XCTAssertTrue(AIGrouping.explain(status: 404, type: "not_found_error", message: "").contains("claude-opus-5-5"))
        XCTAssertEqual(AIGrouping.explain(status: 400, type: "invalid_request_error", message: "max_tokens: too large"), "max_tokens: too large")
        XCTAssertEqual(AIGrouping.explain(status: 418, type: "", message: ""), "The request failed (418).")
    }

    func testSuggestionsAreCheckedAgainstTheFile() throws {
        let e = try books()
        let asked = e.ungroupedAccounts
        let reply = """
        {"assignments":[
          {"account":"6300","grouping":"815-OFFICE","confidence":"medium","reason":"Hosting is an office cost."},
          {"account":"6200","grouping":"803","confidence":"high","reason":"Advertising."},
          {"account":"6200","grouping":"804","confidence":"high","reason":"A second answer for the same account."},
          {"account":"4000","grouping":"803","confidence":"high","reason":"Wasn't asked about."},
          {"account":"9999","grouping":"803","confidence":"high","reason":"Isn't an account."},
          {"account":"1000","grouping":"Cash and equivalents","confidence":"sure","reason":"Bank."}
        ]}
        """
        let found = try AIGrouping.proposals(from: reply, for: e, asked: asked)
        // In chart order; only the accounts asked about; the first answer for each.
        XCTAssertEqual(found.map(\.account), ["1000", "6200", "6300"])
        XCTAssertEqual(found[1], AIGrouping.Proposal(account: "6200", grouping: "803", confidence: "high", reason: "Advertising."))
        XCTAssertEqual(found[2].grouping, "815-OFFICE")
        XCTAssertEqual(found[2].confidence, "medium")
        // A grouping that isn't in the list is never applied: the suggestion is kept, with none.
        XCTAssertNil(found[0].grouping)
        XCTAssertEqual(found[0].confidence, "low")
        XCTAssertTrue(found[0].reason.hasPrefix("Suggested “Cash and equivalents”, which isn't in the grouping list."))

        // A code or a name in place of the id is understood.
        let loose = try AIGrouping.proposals(from: #"{"assignments":[{"account":"6200","grouping":"advertising","confidence":"high","reason":""},{"account":"6300","grouping":"","confidence":"high","reason":"Nothing fits."}]}"#, for: e, asked: asked)
        XCTAssertEqual(loose.map(\.grouping), ["803", nil])
        XCTAssertEqual(loose[1].confidence, "low")

        XCTAssertThrowsError(try AIGrouping.proposals(from: "I couldn't do that.", for: e, asked: asked))
        XCTAssertThrowsError(try AIGrouping.proposals(from: #"{"assignments":"none"}"#, for: e, asked: asked))
        XCTAssertEqual(try AIGrouping.proposals(from: #"{"assignments":[]}"#, for: e, asked: asked), [])
    }

    func testApplyingGroupsOnlyWhatWasAccepted() throws {
        var e = try books()
        let n = AIGrouping.apply([
            AIGrouping.Proposal(account: "6200", grouping: "803", confidence: "high", reason: ""),
            AIGrouping.Proposal(account: "6300", grouping: nil, confidence: "low", reason: ""),
            AIGrouping.Proposal(account: "1000", grouping: "NOT-A-GROUPING", confidence: "high", reason: ""),
            AIGrouping.Proposal(account: "9999", grouping: "803", confidence: "high", reason: ""),
        ], to: &e)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(e.account("6200")?.grouping, "803")
        XCTAssertEqual(e.ungroupedAccounts.map(\.id), ["1000", "6300"])
        // Accounts grouped before are left as they were.
        XCTAssertEqual(e.account("4000")?.grouping, "802")
    }
}
