// ItemIDGrammarTests.swift
// Round-trip and accessor-equivalence tests for the tag grammar. The corpus
// covers every real shape: third-party status tags, agent system tags, Pelmet's
// own items, canonical bundle keys, modules, and degenerate raw values.

import Foundation
import Testing
import PelmetCore

struct ItemIDGrammarTests {
    let corpus: [ItemID] = [
        ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0"),
        ItemID(rawValue: "status:com.sindresorhus.Velja::Left and right arrows in a filled circle"),
        ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.clock"),
        ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.Separator.ABC-123"),
        ItemID(rawValue: "bundle:com.figma.Desktop"),
        ItemID(rawValue: "module:BentoBox"),
        ItemID(rawValue: "status:degenerate-no-separator"),
        ItemID(rawValue: "garbage"),
    ]

    @Test func formattersRoundTripThroughParser() {
        #expect(ItemID.status(bundle: "com.a.B", title: "T").parsed == .status(bundle: "com.a.B", title: "T"))
        #expect(ItemID.module("X").parsed == .module("X"))
        #expect(ItemID.bundleKey("com.a.B").parsed == .bundleKey("com.a.B"))
    }

    @Test func parserAgreesWithFastAccessors() {
        for id in corpus {
            switch id.parsed {
            case .status(let bundle, _):
                #expect(id.bundleID == bundle, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            case .bundleKey(let bundle):
                #expect(id.bundleID == bundle, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            case .module:
                #expect(id.isSystemModule, "\(id.rawValue)")
                #expect(id.bundleID == nil, "\(id.rawValue)")
            case .opaque:
                #expect(id.bundleID == nil, "\(id.rawValue)")
                #expect(!id.isSystemModule, "\(id.rawValue)")
            }
        }
    }

    @Test func sectionKeyCollapsesOnlyThirdPartyStatusTags() {
        #expect(
            ItemID.status(bundle: "com.sindresorhus.Velja", title: "Item-0").sectionKey
                == .bundleKey("com.sindresorhus.Velja")
        )
        let pelmetExtra = ItemID.status(bundle: "app.fif7y.Pelmet", title: "Pelmet.Extra.media")
        #expect(pelmetExtra.sectionKey == pelmetExtra)
        let agentClock = ItemID.status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.clock")
        #expect(agentClock.sectionKey == agentClock)
    }

    @Test func statusTagPrefixMatchesEveryTitleVariant() {
        let prefix = ItemID.statusTagPrefix(bundle: "com.sindresorhus.Velja")
        #expect(ItemID.status(bundle: "com.sindresorhus.Velja", title: "A").rawValue.hasPrefix(prefix))
        #expect(ItemID.status(bundle: "com.sindresorhus.Velja", title: "Item-0").rawValue.hasPrefix(prefix))
        #expect(!ItemID.bundleKey("com.sindresorhus.Velja").rawValue.hasPrefix(prefix))
        #expect(!ItemID.status(bundle: "com.sindresorhus.VeljaX", title: "A").rawValue.hasPrefix(prefix))
    }

    // MARK: - Pelmet's own items

    /// The classifier reads back exactly what ExtraItemSpec/SeparatorSpec mint.
    @Test func pelmetItemClassifierMatchesTheMintedTitles() {
        func id(_ title: String) -> ItemID {
            .status(bundle: PelmetBundle.fallbackID, title: title)
        }
        #expect(id("Pelmet.StatusItem").pelmetItem == .chevron)
        #expect(id(ExtraItemSpec(kind: .mediaControls).itemTitle).pelmetItem == .mediaControls)
        #expect(id(ExtraItemSpec(kind: .cameraMicIndicator).itemTitle).pelmetItem == .cameraMic)
        #expect(id(ExtraItemSpec(kind: .airdrop).itemTitle).pelmetItem == .airdrop)
        #expect(id(ExtraItemSpec(kind: .shortcut).itemTitle).pelmetItem == .shortcut)
        #expect(id(ExtraItemSpec(kind: .appLauncher).itemTitle).pelmetItem == .appLauncher)
        #expect(id(SeparatorSpec(style: .pipe).itemTitle).pelmetItem == .separator)
    }

    /// The classifier keys on the minted TITLE (as `isPelmetExtraID` always
    /// did) — the bundle check belongs to the callers that need it. What it
    /// does fix is the substring match it replaced: `contains("Separator")`
    /// claimed any item whose AX title merely said so.
    @Test func aTitleThatMerelyMentionsSeparatorIsNotOne() {
        let namedLikeOne = ItemID.status(bundle: "com.example.App", title: "Audio Separator")
        #expect(namedLikeOne.pelmetItem == nil)
        #expect(!namedLikeOne.isPelmetSeparator)
        #expect(!MenuBarPolicy.isPelmetExtraID(namedLikeOne))
        #expect(!MenuBarPolicy.isChevronID(namedLikeOne, pelmetBundleID: "com.example.App"))
        // A real separator under Pelmet's own bundle still classifies.
        let real = ItemID.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.x")
        #expect(real.isPelmetSeparator)
    }

    /// The chevron predicate is bundle-scoped: an item titled like the
    /// chevron under someone else's bundle is not Pelmet's boundary.
    @Test func chevronPredicateIsBundleScoped() {
        let impostor = ItemID.status(bundle: "com.example.App", title: "Pelmet.StatusItem")
        #expect(!MenuBarPolicy.isChevronID(impostor, pelmetBundleID: PelmetBundle.fallbackID))
    }

    /// isChevronID is the chevron and nothing else — separators and extras
    /// share the bundle and must not answer to it.
    @Test func chevronPredicateExcludesEveryOtherOwnItem() {
        let bundle = PelmetBundle.fallbackID
        func id(_ title: String) -> ItemID { .status(bundle: bundle, title: title) }
        #expect(MenuBarPolicy.isChevronID(id("Pelmet.StatusItem"), pelmetBundleID: bundle))
        for title in ["Pelmet.MediaControls", "Pelmet.AirDrop", "Pelmet.Separator.abc", "Pelmet.App.abc"] {
            #expect(!MenuBarPolicy.isChevronID(id(title), pelmetBundleID: bundle))
            #expect(MenuBarPolicy.isPelmetExtraID(id(title)))
        }
    }
}
