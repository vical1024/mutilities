import Foundation

struct FinderCutState {
    private(set) var token: UUID?
    private var beforeCopy: Int?
    private var copiedAt: Int?
    var isAwaitingCopy: Bool { beforeCopy != nil && copiedAt == nil }

    mutating func begin(copyChangeCount: Int) -> UUID {
        cancel()
        let id = UUID()
        token = id
        beforeCopy = copyChangeCount
        return id
    }

    mutating func observe(changeCount: Int) {
        if let copiedAt, copiedAt != changeCount { cancel() }
        else if let beforeCopy, beforeCopy != changeCount { copiedAt = changeCount }
    }

    mutating func consume(changeCount: Int) -> Bool {
        observe(changeCount: changeCount)
        let matches = copiedAt == changeCount
        cancel()
        return matches
    }

    mutating func cancel() {
        token = nil
        beforeCopy = nil
        copiedAt = nil
    }
}
