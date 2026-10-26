import Foundation
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Converter

/// Home's Clipboard row pastes copied PDFs and documents, not just photos and videos.
@Suite(.serialized) @MainActor struct ClipboardDocumentTests {
    @Test func aCopiedPDFOpensAsADocument() throws {
        let board = UIPasteboard.general
        let data = try #require(TestSupport.makePDF(pages: 2).dataRepresentation())
        board.setData(data, forPasteboardType: UTType.pdf.identifier)
        defer { board.items = [] }

        #expect(ImportService().pasteboardImportLabel() == nil, "The media importer doesn't take PDFs")
        #expect(FileIntake.pasteboardDocumentFormat() == .pdf)
        let file = try #require(try FileIntake.importPasteboard().first)
        #expect(file.format == .pdf)
        #expect(PDFDocument(url: file.url)?.pageCount == 2)

        let home = HomeViewModel()
        #expect(home.pasteboardDocumentFormat == .pdf)
        #expect(home.pasteboardImportLabel == "PDF", "The Clipboard row is enabled for the PDF")
    }

    @Test func copiedTextIsNotADocument() {
        let board = UIPasteboard.general
        board.string = "Meet at 5"
        defer { board.items = [] }
        #expect(FileIntake.pasteboardDocumentFormat() == nil)
        #expect(FileIntake.documentFormat(forPasteboardType: UTType.html.identifier) == nil)
        #expect(FileIntake.documentFormat(forPasteboardType: UTType.pdf.identifier) == .pdf)
    }
}

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
