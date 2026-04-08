//
//  askTests.swift
//  askTests
//
//  Created by Kevin Hill on 3/28/26.
//

import Testing
import Foundation
@testable import ask

// MARK: - Test helpers

/// Lightweight RKBlock factory for unit tests — bypasses the CKRecord initialiser.
extension RKBlock {
    static func make(
        id: String = UUID().uuidString,
        machineID: String = "machine-1",
        scriptID: String = "test-script",
        blockType: RKBlockType,
        payloadJSON: String = "{}",
        showsInInbox: Bool = false,
        createdAt: Date = Date()
    ) -> RKBlock {
        RKBlock(
            id: id,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: nil,
            scriptIcon: nil,
            scriptIconData: nil,
            scriptIconSVG: nil,
            blockType: blockType,
            payloadJSON: payloadJSON,
            createdAt: createdAt,
            expiresAt: nil,
            scriptType: "tile",
            showsInInbox: showsInInbox
        )
    }
}

// MARK: - RKUrgency

@Suite("RKUrgency")
struct RKUrgencyTests {
    @Test func sortRankOrder() {
        #expect(RKUrgency.urgent.sortRank < RKUrgency.warning.sortRank)
        #expect(RKUrgency.warning.sortRank < RKUrgency.info.sortRank)
    }

    @Test func sortRankUsedForSorting() {
        let urgencies: [RKUrgency] = [.info, .urgent, .warning]
        let sorted = urgencies.sorted { $0.sortRank < $1.sortRank }
        #expect(sorted == [.urgent, .warning, .info])
    }
}

// MARK: - RKBlock urgency

@Suite("RKBlock.effectiveUrgency")
struct RKBlockUrgencyTests {
    @Test func inboxBlockWithNoUrgencyDefaultsToWarning() {
        let block = RKBlock.make(blockType: .confirmation,
                                 payloadJSON: #"{"title":"t","body":"b","options":["OK"]}"#,
                                 showsInInbox: true)
        #expect(block.urgency == nil)
        #expect(block.effectiveUrgency == .warning)
    }

    @Test func inboxBlockWithExplicitUrgencyUsesIt() {
        let block = RKBlock.make(blockType: .confirmation,
                                 payloadJSON: #"{"title":"t","body":"b","options":["OK"],"urgency":"urgent"}"#,
                                 showsInInbox: true)
        #expect(block.urgency == .urgent)
        #expect(block.effectiveUrgency == .urgent)
    }

    @Test func nonResponseBlockHasNilEffectiveUrgency() {
        let block = RKBlock.make(blockType: .status,
                                 payloadJSON: #"{"label":"ok"}"#,
                                 showsInInbox: false)
        #expect(block.effectiveUrgency == nil)
    }

    @Test func quickReplyDefaultsToWarning() {
        let block = RKBlock.make(blockType: .quickReply,
                                 payloadJSON: #"{"title":"Deploy?","options":["Yes","No"]}"#,
                                 showsInInbox: true)
        #expect(block.effectiveUrgency == .warning)
    }

    @Test func quickReplyWithUrgentParsesCorrectly() {
        let block = RKBlock.make(blockType: .quickReply,
                                 payloadJSON: #"{"title":"Delete?","options":["Yes","No"],"urgency":"urgent"}"#,
                                 showsInInbox: true)
        #expect(block.effectiveUrgency == .urgent)
    }
}

// MARK: - RKQuickReplyPayload decoding

@Suite("RKQuickReplyPayload")
@MainActor
struct RKQuickReplyPayloadTests {
    @Test func decodesAllFields() throws {
        let json = #"{"title":"Deploy to prod?","description":"Branch: main","options":["Deploy","Cancel"],"allow_custom":true,"urgency":"warning"}"#
        let payload = try JSONDecoder().decode(RKQuickReplyPayload.self, from: Data(json.utf8))
        #expect(payload.title == "Deploy to prod?")
        #expect(payload.description == "Branch: main")
        #expect(payload.options == ["Deploy", "Cancel"])
        #expect(payload.allowCustom == true)
        #expect(payload.urgency == .warning)
    }

    @Test func decodesMinimalPayload() throws {
        let json = #"{"title":"Continue?","options":["Yes","No"]}"#
        let payload = try JSONDecoder().decode(RKQuickReplyPayload.self, from: Data(json.utf8))
        #expect(payload.title == "Continue?")
        #expect(payload.description == nil)
        #expect(payload.allowCustom == nil)
        #expect(payload.urgency == nil)
    }
}

// MARK: - ScriptGroup urgency and machine count

@Suite("ScriptGroup")
struct ScriptGroupTests {
    @Test func dominantUrgencyPicksMostUrgent() {
        let blocks = [
            RKBlock.make(blockType: .confirmation,
                         payloadJSON: #"{"title":"t","body":"b","options":["OK"],"urgency":"info"}"#,
                         showsInInbox: true),
            RKBlock.make(blockType: .confirmation,
                         payloadJSON: #"{"title":"t","body":"b","options":["OK"],"urgency":"urgent"}"#,
                         showsInInbox: true),
            RKBlock.make(blockType: .confirmation,
                         payloadJSON: #"{"title":"t","body":"b","options":["OK"],"urgency":"warning"}"#,
                         showsInInbox: true),
        ]
        let group = ScriptGroup(scriptID: "s", blocks: blocks)
        #expect(group.dominantUrgency == .urgent)
    }

    @Test func dominantUrgencyIgnoresNonInboxBlocks() {
        // agentSession is requiresResponse but NOT showsInInbox — should be excluded
        let blocks = [
            RKBlock.make(blockType: .agentSession,
                         payloadJSON: #"{"session_id":"x","project":"p"}"#,
                         showsInInbox: false),
        ]
        let group = ScriptGroup(scriptID: "s", blocks: blocks)
        #expect(group.dominantUrgency == nil)
    }

    @Test func dominantUrgencyDefaultsToWarningForInboxBlockWithNoUrgency() {
        let blocks = [
            RKBlock.make(blockType: .confirmation,
                         payloadJSON: #"{"title":"t","body":"b","options":["OK"]}"#,
                         showsInInbox: true),
        ]
        let group = ScriptGroup(scriptID: "s", blocks: blocks)
        #expect(group.dominantUrgency == .warning)
    }

    @Test func machineCountDistinct() {
        let blocks = [
            RKBlock.make(machineID: "m1", blockType: .status),
            RKBlock.make(machineID: "m2", blockType: .status),
            RKBlock.make(machineID: "m1", blockType: .confirmation, showsInInbox: true),
        ]
        let group = ScriptGroup(scriptID: "s", blocks: blocks)
        #expect(group.machineCount == 2)
    }

    @Test func machineCountSingleMachine() {
        let blocks = [
            RKBlock.make(machineID: "m1", blockType: .status),
            RKBlock.make(machineID: "m1", blockType: .confirmation, showsInInbox: true),
        ]
        let group = ScriptGroup(scriptID: "s", blocks: blocks)
        #expect(group.machineCount == 1)
    }
}
