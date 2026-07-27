import Testing

@Suite struct SmokeTests {
    @Test func projectBuildsAndTestsRun() {
        #expect(Bool(true))
    }
}
