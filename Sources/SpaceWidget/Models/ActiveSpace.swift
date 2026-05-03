import Foundation

struct ActiveSpace: Equatable {
    let id: UInt64
    let ordinal: Int
    let uuid: String?

    init(id: UInt64, ordinal: Int, uuid: String? = nil) {
        self.id = id
        self.ordinal = ordinal
        self.uuid = uuid
    }
}
