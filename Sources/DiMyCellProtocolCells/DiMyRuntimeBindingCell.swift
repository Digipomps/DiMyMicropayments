import CellBase
import Foundation

open class DiMyRuntimeBindingCell: GeneralCell {
    public required init(owner: Identity) async {
        await super.init(owner: owner)
    }

    public required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    func installRuntimeBindings(owner: Identity) async {}

    public override func installCellRuntimeBindingsForAccess() async throws {
        // GeneralCell supplies an instance-bound installation token and
        // serializes this hook for fresh, decoded, persisted and Explore paths.
        // Runtime installation is not caller authorization; every operation
        // still validates its requester independently.
        await installRuntimeBindings(owner: storedOwnerIdentity)
    }

    func ensureAgreementGrant(_ permissions: String, for keypath: String) {
        guard !agreementTemplate.grants.contains(where: {
            $0.keypath == keypath && $0.permission.permissionString == permissions
        }) else {
            return
        }
        agreementTemplate.addGrant(permissions, for: keypath)
    }

    /// Compatibility entrypoint for existing hosts. Runtime readiness is now
    /// owned by GeneralCell so keys/Explore and get/set share one coordinator.
    public func ensureRuntimeBindings(requester: Identity) async throws {
        _ = requester
        try await ensureRuntimeReady()
    }
}
