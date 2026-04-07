import Testing
@testable import AskMacCore

@Suite("VersionComparison")
struct VersionComparisonTests {

    // MARK: - Equal versions

    @Test func equalSimple() {
        #expect(VersionComparison.compare("1.0.0", "1.0.0") == .orderedSame)
    }

    @Test func equalSingleComponent() {
        #expect(VersionComparison.compare("2", "2") == .orderedSame)
    }

    @Test func equalWithTrailingZero() {
        // "1.0" vs "1.0.0" — trailing component defaults to 0
        #expect(VersionComparison.compare("1.0", "1.0.0") == .orderedSame)
    }

    // MARK: - Ascending (a < b)

    @Test func ascendingPatch() {
        #expect(VersionComparison.compare("1.0.0", "1.0.1") == .orderedAscending)
    }

    @Test func ascendingMinor() {
        #expect(VersionComparison.compare("1.0.9", "1.1.0") == .orderedAscending)
    }

    @Test func ascendingMajor() {
        #expect(VersionComparison.compare("0.9.9", "1.0.0") == .orderedAscending)
    }

    @Test func ascendingLargeNumbers() {
        #expect(VersionComparison.compare("1.9.0", "1.10.0") == .orderedAscending)
    }

    // MARK: - Descending (a > b)

    @Test func descendingPatch() {
        #expect(VersionComparison.compare("1.0.2", "1.0.1") == .orderedDescending)
    }

    @Test func descendingMinor() {
        #expect(VersionComparison.compare("1.2.0", "1.1.9") == .orderedDescending)
    }

    @Test func descendingMajor() {
        #expect(VersionComparison.compare("2.0.0", "1.9.9") == .orderedDescending)
    }

    // MARK: - Different component counts

    @Test func shortVsLong() {
        #expect(VersionComparison.compare("1", "1.0.0") == .orderedSame)
        #expect(VersionComparison.compare("1", "1.0.1") == .orderedAscending)
        #expect(VersionComparison.compare("1.1", "1.0.9") == .orderedDescending)
    }

    // MARK: - Non-numeric fallback

    @Test func nonNumericFallback() {
        // When no components are numeric, falls back to string comparison
        #expect(VersionComparison.compare("alpha", "beta") == .orderedAscending)
        #expect(VersionComparison.compare("beta", "alpha") == .orderedDescending)
        #expect(VersionComparison.compare("alpha", "alpha") == .orderedSame)
    }
}
