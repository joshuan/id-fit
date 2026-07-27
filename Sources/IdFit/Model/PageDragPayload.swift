import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type, so page drags are only accepted by our own grid and
    /// arbitrary text dropped from other apps is ignored.
    static let idFitPage = UTType(exportedAs: "net.shershnev.id-fit.page")
}

struct PageDragPayload: Codable, Transferable, Sendable {
    var pageID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .idFitPage)
    }
}
