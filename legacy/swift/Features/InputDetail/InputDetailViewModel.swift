import Foundation
import Observation

@MainActor
@Observable
final class InputDetailViewModel {
    let media: MediaFile

    init(media: MediaFile) {
        self.media = media
    }
}
