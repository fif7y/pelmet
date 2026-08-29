// NookMigrationTests.swift
// Locks the nook → Pelmet defaults-migration rewrites: key names (settings
// blob key, NSStatusItem autosave keys) and ItemID strings inside the
// settings JSON blob.

import Foundation
import Testing
@testable import Pelmet

struct NookMigrationTests {
    @Test func settingsKeyRenames() {
        #expect(
            NookMigration.migratedKey("app.fif7y.Nook.settings.v1")
                == "app.fif7y.Pelmet.settings.v1")
    }

    @Test func statusItemAutosaveKeyRenames() {
        #expect(
            NookMigration.migratedKey("NSStatusItem Preferred Position Nook.Separator.ABC-123")
                == "NSStatusItem Preferred Position Pelmet.Separator.ABC-123")
        #expect(
            NookMigration.migratedKey("NSStatusItem Visible Nook.StatusItem")
                == "NSStatusItem Visible Pelmet.StatusItem")
    }

    @Test func unrelatedKeysUntouched() {
        #expect(NookMigration.migratedKey("NSWindow Frame settings") == "NSWindow Frame settings")
    }

    @Test func blobRewritesItemIDs() throws {
        let json = #"{"sectionModel":{"assignments":{"status:app.fif7y.Nook::Nook.MediaControls":"hidden","status:app.fif7y.Nook::Nook.Separator.AB-12":"visible","status:com.sindresorhus.Velja::Item-0":"hidden"}}}"#
        let out = try #require(NookMigration.migratedValue(Data(json.utf8)) as? Data)
        let text = try #require(String(data: out, encoding: .utf8))
        #expect(text.contains("status:app.fif7y.Pelmet::Pelmet.MediaControls"))
        #expect(text.contains("status:app.fif7y.Pelmet::Pelmet.Separator.AB-12"))
        #expect(text.contains("status:com.sindresorhus.Velja::Item-0"))
        #expect(!text.contains("Nook"))
    }

    @Test func nonBlobValuesPassThrough() {
        #expect(NookMigration.migratedValue(42.5) as? Double == 42.5)
        let plain = Data("unrelated".utf8)
        #expect(NookMigration.migratedValue(plain) as? Data == plain)
    }
}
