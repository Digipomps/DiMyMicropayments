import DiMyAccessCell
import DiMyCellProtocolCells
import DiMyMintClient
import DiMyWalletCell

public enum DiMyMicropaymentsBootstrap {
    public static var version: String { "0.2.0-cellprotocol-bootstrap" }
}

public typealias MicropaymentWalletCell = WalletCell
public typealias MicropaymentAccessCell = AccessCell
public typealias MicropaymentMintClient = MintClient
public typealias MicropaymentRuntimeRegistration = DiMyCellRuntimeRegistration
