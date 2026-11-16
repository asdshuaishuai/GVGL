import XCTest
import GVGLCore
import GVGLQuery

/// The scoring contract is implemented twice on purpose (Swift daemon-side
/// library + Python reference client), so the two must be pinned to the same
/// vectors. `Tests/Fixtures/query_vectors.json` is the single source of truth;
/// this suite and `scripts/test_scoring_parity.py` both read it. A drift in
/// weights, bands or the applicable-weight normalization fails here.
final class ScoringParityTests: XCTestCase {
    private let screen = ScreenInfo(width: 3440, height: 1440)

    private struct FixtureGeometry: Decodable {
        let screen: [Double]
        let window: [Double]
    }

    private struct FixtureEntity: Decodable {
        let id: String
        let role: String
        let title: String?
        let detail: String?
        let identifier: String?
        let value: String?
        let placeholder: String?
        let enabled: Bool?
        let actions: [String]?
        let appID: String?
        let pid: Int?
        let windowID: String?
        let entityParentID: String?
        let geometry: FixtureGeometry
    }

    private struct FixtureParams: Decodable {
        let role: String?
        let label: String?
        let refID: String?
        let refDir: String?
    }

    private struct FixtureCase: Decodable {
        let name: String
        let target: String
        let entities: [FixtureEntity]
        let params: FixtureParams
        let expected: [String: Double]
    }

    private struct Fixture: Decodable {
        let cases: [FixtureCase]
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/query_vectors.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func entity(_ fixture: FixtureEntity) -> Entity {
        func rect(_ a: [Double]) -> NormRect {
            NormRect(x: a[0], y: a[1], w: a[2], h: a[3])
        }
        return Entity(
            id: fixture.id, role: fixture.role, title: fixture.title,
            detail: fixture.detail, identifier: fixture.identifier,
            value: fixture.value, placeholder: fixture.placeholder,
            enabled: fixture.enabled ?? true, actions: fixture.actions ?? [],
            axParentID: nil, entityParentID: fixture.entityParentID,
            windowID: fixture.windowID, appID: fixture.appID ?? "pid:1",
            pid: Int32(fixture.pid ?? 1), geometry: Geometry(
                screen: rect(fixture.geometry.screen),
                window: rect(fixture.geometry.window)
            )
        )
    }

    func testSwiftScoringMatchesPinnedVectors() throws {
        let fixture = try loadFixture()
        for testCase in fixture.cases {
            let entities = testCase.entities.map(entity)
            let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let params = QueryParams(
                role: testCase.params.role, label: testCase.params.label,
                refID: testCase.params.refID, refDir: testCase.params.refDir, top: 5
            )
            let ref = testCase.params.refID.flatMap { byID[$0] }

            guard let target = byID[testCase.target] else {
                XCTFail("\(testCase.name): target \(testCase.target) missing")
                continue
            }
            let (total, breakdown) = QueryEngine.score(
                entity: target, params: params, ref: ref,
                refRegion: ref?.geometry.region.rawValue, byID: byID
            )

            for key in ["semantic", "role", "spatial", "size", "topology"] {
                guard let expected = testCase.expected[key],
                      let got = breakdown[key] else { continue }
                XCTAssertEqual(got, expected, accuracy: 1e-9,
                               "\(testCase.name): \(key) tier")
            }
            XCTAssertEqual(total, testCase.expected["total"]!, accuracy: 1e-9,
                           "\(testCase.name): total")
        }
    }
}
