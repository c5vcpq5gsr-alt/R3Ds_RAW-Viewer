import Testing
@testable import RAWViewer

@Test("Integrated RAW Viewer checks")
func integratedChecks() async {
    #expect(await SelfTestRunner.run() == 0)
}
