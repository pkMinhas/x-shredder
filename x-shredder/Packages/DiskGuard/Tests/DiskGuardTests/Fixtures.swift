import Foundation
import XCTest
@testable import DiskGuard

struct DiskFixture: Decodable {
    var origin: String
    var note: String
    var description: DiskDescription
    var protectedWholeDisks: [String]?

    var context: SystemContext {
        SystemContext(protectedWholeDisks: protectedWholeDisks.map(Set.init))
    }
}

struct TopologyFixture: Decodable {
    var nodes: [MediaNode]
    var mounts: [Mount]
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    }

    static func disk(_ name: String) throws -> DiskFixture {
        try JSONDecoder().decode(DiskFixture.self, from: Data(contentsOf: url(name)))
    }

    static func topology(_ name: String) throws -> TopologyFixture {
        try JSONDecoder().decode(TopologyFixture.self, from: Data(contentsOf: url(name)))
    }

    /// An eligible disk used as the starting point for single-field changes.
    static func eligibleCard() throws -> DiskFixture {
        try disk("usb-reader-sd-card")
    }
}
