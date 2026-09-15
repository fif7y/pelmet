import Foundation
import Testing
@testable import PelmetEngine

struct StatusItemTitleTests {
    @Test(arguments: [24.0, 234, 500, 900])
    func statusTitlesHaveNoWidthLimit(width: Double) {
        let group = CGRect(x: 800, y: 0, width: width, height: 39)
        let items = [
            StatusItemTitle.Candidate(title: "Apple", frame: CGRect(x: 0, y: 0, width: 30, height: 24), isExtrasBar: false),
            StatusItemTitle.Candidate(title: "Long task title", frame: group.insetBy(dx: 2, dy: 8), isExtrasBar: true),
        ]
        #expect(StatusItemTitle.resolve(items, groupFrame: group) == "Long task title")
    }

    @Test func multipleStatusItemsMatchTheirOwnFrame() {
        let items = [
            StatusItemTitle.Candidate(title: "First", frame: CGRect(x: 500, y: 8, width: 600, height: 24), isExtrasBar: true),
            StatusItemTitle.Candidate(title: "Second", frame: CGRect(x: 1100, y: 8, width: 30, height: 24), isExtrasBar: true),
        ]
        #expect(StatusItemTitle.resolve(items, groupFrame: CGRect(x: 1100, y: 0, width: 30, height: 39)) == "Second")
    }

    @Test func missingExtrasAttributeUsesOverlappingItem() {
        let group = CGRect(x: 900, y: 0, width: 600, height: 39)
        #expect(StatusItemTitle.resolve([
            .init(title: "Wide", frame: group, isExtrasBar: false),
        ], groupFrame: group) == "Wide")
    }

    @Test func missingGeometryRequiresExplicitSingleExtrasItem() {
        let group = CGRect(x: 900, y: 0, width: 600, height: 39)
        #expect(StatusItemTitle.resolve([.init(title: "Apple", frame: nil, isExtrasBar: false)], groupFrame: group) == nil)
        #expect(StatusItemTitle.resolve([.init(title: "Task", frame: nil, isExtrasBar: true)], groupFrame: group) == "Task")
        #expect(StatusItemTitle.resolve([
            .init(title: "One", frame: nil, isExtrasBar: true),
            .init(title: "Two", frame: nil, isExtrasBar: true),
        ], groupFrame: group) == nil)
    }

    @Test func offDisplayOrUntitledItemsDoNotBorrowAnotherTitle() {
        let group = CGRect(x: 900, y: 0, width: 600, height: 39)
        #expect(StatusItemTitle.resolve([
            .init(title: "Other display", frame: group.offsetBy(dx: 0, dy: 1200), isExtrasBar: true),
            .init(title: "", frame: group, isExtrasBar: true),
        ], groupFrame: group) == nil)
    }
}
