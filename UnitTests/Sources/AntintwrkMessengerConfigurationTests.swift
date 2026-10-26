// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

@testable import ElementX
import SwiftUI
import Testing

@MainActor
struct AntintwrkMessengerConfigurationTests {
    @Test func callbackCannotLeaveOurAppOrContainUserInfo() throws {
        let valid = try #require(URL(string: "https://antintwrk.com/oauth/ios/com.antintwrk.app?code=fixture&state=fixture"))
        let foreign = try #require(URL(string: "https://evil.test/oauth/ios/com.antintwrk.app?code=fixture"))
        let password = try #require(URL(string: "https://user:fixture@antintwrk.com/oauth/ios/com.antintwrk.app"))
        let otherPath = try #require(URL(string: "https://antintwrk.com/oauth/ios/other.app"))
        #expect(AntintwrkMessengerBootstrap.isOwnCallback(valid))
        #expect(!AntintwrkMessengerBootstrap.isOwnCallback(foreign))
        #expect(!AntintwrkMessengerBootstrap.isOwnCallback(password))
        #expect(!AntintwrkMessengerBootstrap.isOwnCallback(otherPath))
    }
    
    @Test func recoveryNoticeKeepsCriticalAndForeignProvenance() {
        var properties = RoomTimelineItemProperties(encryptionAuthenticity: .notGuaranteed(color: .gray))
        #expect(properties.presentedAuthenticity(ownUserID: "@u18:antintwrk.com", senderID: "@u19:antintwrk.com") == nil)
        #expect(properties.encryptionAuthenticity != nil)
        #expect(properties.presentedAuthenticity(ownUserID: "@u18:antintwrk.com", senderID: "@foreign:example.com") != nil)
        properties.encryptionForwarder = .init(id: "@u20:antintwrk.com")
        #expect(properties.presentedAuthenticity(ownUserID: "@u18:antintwrk.com", senderID: "@u19:antintwrk.com") != nil)
        properties.encryptionForwarder = nil
        properties.encryptionAuthenticity = .verificationViolation(color: .red)
        #expect(properties.presentedAuthenticity(ownUserID: "@u18:antintwrk.com", senderID: "@u19:antintwrk.com") != nil)
    }
    
    @Test func localChatDeletionKeepsAccountsSeparateAndRevealsNewMessages() throws {
        let suite = "antintwrk-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AntintwrkHiddenChats(actor: "@u18:antintwrk.com", store: defaults)
        let second = AntintwrkHiddenChats(actor: "@u19:antintwrk.com", store: defaults)
        let date = Date(timeIntervalSince1970: 100)
        first.hide("!fixture:antintwrk.com", lastMessage: date)
        #expect(first.isHidden("!fixture:antintwrk.com", lastMessage: date))
        #expect(!second.isHidden("!fixture:antintwrk.com", lastMessage: date))
        #expect(!first.isHidden("!fixture:antintwrk.com", lastMessage: date.addingTimeInterval(1)))
        first.hide("!fixture:antintwrk.com", lastMessage: nil)
        first.reveal("!fixture:antintwrk.com")
        #expect(!first.isHidden("!fixture:antintwrk.com", lastMessage: nil))
    }
    
    @Test func socialIdentityParserRejectsOtherRealmsAndAmbiguousNumbers() {
        #expect(AntintwrkSocialDirectory.socialID("@u18:antintwrk.com") == "18")
        #expect(AntintwrkSocialDirectory.socialID("@u018:antintwrk.com") == nil)
        #expect(AntintwrkSocialDirectory.socialID("@u18:matrix.antimsg.com") == nil)
    }
    
    @Test func incomingShareRejectsPrivateFilesAndOversizedText() throws {
        let privateURL = URL.documentsDirectory.appendingPathComponent("fixture.jpg")
        #expect(throws: (any Error).self) {
            _ = try AntintwrkIncomingShare(.mediaFiles(roomID: nil, mediaFiles: [.init(url: privateURL, suggestedName: "fixture.jpg")]))
        }
        #expect(throws: (any Error).self) { _ = try AntintwrkIncomingShare(.text(roomID: nil, text: String(repeating: "x", count: 100_001))) }
        let first = try AntintwrkIncomingShare(.text(roomID: nil, text: "fixture"))
        let second = try AntintwrkIncomingShare(.text(roomID: nil, text: "fixture"))
        #expect(first.id != second.id)
        #expect(first.script?.contains("fixture") == true)
    }
    
    @Test func passkeyOptionsRejectForeignRelyingPartyAndWeakChallenge() throws {
        let challenge = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let ticket = String(repeating: "a", count: 64)
        let valid: [String: Any] = ["ticket": ticket, "options": ["rpId": "antintwrk.com", "challenge": challenge]]
        #expect(try AntintwrkPasskeyOptions(valid).challenge.count == 32)
        let foreign: [String: Any] = ["ticket": ticket, "options": ["rpId": "evil.test", "challenge": challenge]]
        #expect(throws: (any Error).self) { _ = try AntintwrkPasskeyOptions(foreign) }
        let weak: [String: Any] = ["ticket": ticket, "options": ["rpId": "antintwrk.com", "challenge": "YQ"]]
        #expect(throws: (any Error).self) { _ = try AntintwrkPasskeyOptions(weak) }
    }
    
    @Test func messengerConfigurationHasOnlyOwnEndpoints() {
        let settings = AntintwrkAppSettingsHook().configure(AppSettings.volatile())
        #expect(settings.pushGatewayNotifyEndpoint.absoluteString == "https://push.antimsg.com/_matrix/push/v1/notify")
        #expect(settings.oAuthConfiguration.redirectURI.host == "antintwrk.com")
        #expect(settings.oAuthConfiguration.clientURI.host == "antintwrk.com")
        #expect(AntintwrkClientConfiguration.messengerOrigin.host == "matrix.antimsg.com")
        #expect(AntintwrkClientConfiguration.nativeOrigin.host == "antimsg.com")
        #expect(settings.allowOtherAccountProviders == false)
        #expect(settings.hideBrandChrome)
        #expect(settings.analyticsConsentState == .optedOut)
    }
}
