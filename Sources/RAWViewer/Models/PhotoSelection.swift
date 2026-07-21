import Foundation

struct PhotoSelectionModifiers: OptionSet, Sendable {
    let rawValue: Int

    static let toggle = PhotoSelectionModifiers(rawValue: 1 << 0)
    static let range = PhotoSelectionModifiers(rawValue: 1 << 1)
}

struct PhotoSelection: Equatable, Sendable {
    private(set) var ids: Set<PhotoAsset.ID> = []
    private(set) var primaryID: PhotoAsset.ID?
    private(set) var anchorID: PhotoAsset.ID?

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    mutating func select(
        _ id: PhotoAsset.ID,
        orderedIDs: [PhotoAsset.ID],
        modifiers: PhotoSelectionModifiers = []
    ) {
        guard orderedIDs.contains(id) else { return }

        if modifiers.contains(.range) {
            let anchor = anchorID.flatMap { orderedIDs.contains($0) ? $0 : nil }
                ?? primaryID.flatMap { orderedIDs.contains($0) ? $0 : nil }
                ?? id
            guard let anchorIndex = orderedIDs.firstIndex(of: anchor),
                  let targetIndex = orderedIDs.firstIndex(of: id) else { return }
            let rangeIDs = Set(orderedIDs[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)])
            ids = modifiers.contains(.toggle) ? ids.union(rangeIDs) : rangeIDs
            primaryID = id
            anchorID = anchor
            return
        }

        if modifiers.contains(.toggle) {
            if ids.remove(id) == nil {
                ids.insert(id)
                primaryID = id
                anchorID = id
            } else {
                primaryID = orderedIDs.first(where: ids.contains)
                if anchorID == id || anchorID.map({ !ids.contains($0) }) == true {
                    anchorID = primaryID
                }
            }
            return
        }

        ids = [id]
        primaryID = id
        anchorID = id
    }

    mutating func replace(with id: PhotoAsset.ID?) {
        ids = id.map { [$0] } ?? []
        primaryID = id
        anchorID = id
    }

    mutating func selectAll(_ orderedIDs: [PhotoAsset.ID]) {
        ids = Set(orderedIDs)
        guard !ids.isEmpty else {
            primaryID = nil
            anchorID = nil
            return
        }
        if primaryID.map({ ids.contains($0) }) != true {
            primaryID = orderedIDs.first
        }
        anchorID = primaryID
    }

    mutating func prune(to orderedIDs: [PhotoAsset.ID]) {
        ids.formIntersection(orderedIDs)
        if primaryID.map({ ids.contains($0) }) != true {
            primaryID = orderedIDs.first(where: ids.contains)
        }
        if anchorID.map({ ids.contains($0) }) != true {
            anchorID = primaryID
        }
    }

    mutating func clear() {
        replace(with: nil)
    }
}
