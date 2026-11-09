// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IERC8004
 * @notice Interface for ERC-8004: Confirmation of Payee (CoP) Identity Registry.
 * Allows entities (businesses, merchants, individuals, AI agents) to bind canonical verified identities
 * (such as legal names, tax IDs, routing tags, or ENS/DNS handles) to EVM wallet addresses.
 */
interface IERC8004 {
    enum VerificationStatus { UNVERIFIED, PENDING, VERIFIED, REVOKED }

    struct PayeeIdentity {
        string identifier;          // Human-readable identifier (e.g. "acme.corp", "alice.payee")
        string legalName;           // Registered legal or display name
        string metadataURI;         // IPFS or HTTPS URI with KYC/credential proofs
        VerificationStatus status;  // Current status
        uint256 registeredAt;       // Timestamp of initial registration
        uint256 updatedAt;          // Timestamp of last status modification
        address verifier;           // Address of authorized verification authority
    }

    event PayeeRegistered(address indexed payee, string identifier, string legalName);
    event PayeeVerified(address indexed payee, address indexed verifier, VerificationStatus status);
    event PayeeRevoked(address indexed payee, address indexed revoker, string reason);

    function registerPayee(string calldata identifier, string calldata legalName, string calldata metadataURI) external;
    function verifyPayee(address payee, VerificationStatus status) external;
    function revokePayee(address payee, string calldata reason) external;
    function getPayee(address payee) external view returns (PayeeIdentity memory);
    function isVerifiedPayee(address payee) external view returns (bool);
    function resolveIdentifier(string calldata identifier) external view returns (address);
}
