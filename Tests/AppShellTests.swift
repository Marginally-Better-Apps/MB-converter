import Foundation
import Testing
@testable import Converter

/// Leaving the convert screen only asks "Discard this conversion?" when there is something to lose.
@Suite @MainActor struct ConvertDiscardTests {
    private func model() async throws -> OutputConfigViewModel {
        let url = try TestSupport.writeImage(TestSupport.makeImage(width: 64, height: 48))
        let model = OutputConfigViewModel(input: try await MediaInspector.inspect(url: url))
        model.markChoicesAsDefaults()
        return model
    }

    @Test func anUntouchedFileLeavesWithoutAsking() async throws {
        let model = try await model()
        #expect(!model.hasUserChanges)
        await model.loadDiscoveredMetadataIfNeeded()
        #expect(!model.hasUserChanges, "Reading the file's metadata isn't an edit")
    }

    @Test func changedSettingsAsk() async throws {
        let model = try await model()
        await model.loadDiscoveredMetadataIfNeeded()
        let original = model.selectedFormat
        model.selectedFormat = try #require(model.formats.first { $0 != original })
        #expect(model.hasUserChanges, "A different output format is a change")
    }

    @Test func undoingAnEditMeansNothingToLose() async throws {
        let model = try await model()
        await model.loadDiscoveredMetadataIfNeeded()
        model.isMirrored = true
        #expect(model.hasUserChanges)
        model.isMirrored = false
        #expect(!model.hasUserChanges)

        model.removeAllMetadata.toggle()
        #expect(model.hasUserChanges, "Metadata choices count")
        model.removeAllMetadata.toggle()
        if !model.metadataFieldRows.isEmpty {
            model.metadataFieldRows[0].isRemoved.toggle()
            #expect(model.hasUserChanges, "Editing a metadata field counts")
        }
    }
}
