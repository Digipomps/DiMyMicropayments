import XCTest
import DiMyCellProtocolCells

// A host imports the public module, without @testable privileges.
private final class HostBoundWallet: DiMyWalletRuntimeCell {
    override class var boundMintKeyID: String? { "host-issuer" }
}

final class PublicIssuerSubclassTests: XCTestCase {
    func testHostCanDeclareItsIssuerBindingUsingThePublicAPI() {
        XCTAssertEqual(HostBoundWallet.boundMintKeyID, "host-issuer")
    }
}
