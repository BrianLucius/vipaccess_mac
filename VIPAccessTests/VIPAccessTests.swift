import Testing
@testable import VIPAccess

@Suite("VIPAccess App Tests")
struct VIPAccessTests {
    @Test("App module is importable")
    func appModuleImports() {
        // Verifies the VIPAccess target compiles and is importable
        #expect(Bool(true))
    }
}
