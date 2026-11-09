// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC8004.sol";

/**
 * @title ERC8004Registry
 * @author Alfredo Alvarado (AevumPay Protocol)
 * @notice Canonical ERC-8004 Confirmation of Payee (CoP) Registry implementation for QDay Aevum Testnet.
 * Provides verifiable identity-to-address mappings to eliminate misdirected payments and fraudulent merchant invoicing.
 */
contract ERC8004Registry is IERC8004 {
    address public owner;
    
    // Mapping from authorized verifier address to active permission
    mapping(address => bool) public authorizedVerifiers;

    // Mapping from payee address to their registered identity
    mapping(address => PayeeIdentity) private _payees;

    // Mapping from lowercase hash of unique identifier to registered address
    mapping(bytes32 => address) private _identifierToAddress;

    modifier onlyOwner() {
        require(msg.sender == owner, "ERC8004: caller is not the owner");
        _;
    }

    modifier onlyVerifier() {
        require(authorizedVerifiers[msg.sender] || msg.sender == owner, "ERC8004: caller is not an authorized verifier");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedVerifiers[msg.sender] = true;
    }

    function setVerifier(address verifier, bool isAuthorized) external onlyOwner {
        require(verifier != address(0), "ERC8004: zero address verifier");
        authorizedVerifiers[verifier] = isAuthorized;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ERC8004: zero address owner");
        owner = newOwner;
    }

    /**
     * @notice Allows a payee to self-register their identity and request CoP verification.
     */
    function registerPayee(
        string calldata identifier,
        string calldata legalName,
        string calldata metadataURI
    ) external override {
        require(bytes(identifier).length > 0, "ERC8004: empty identifier");
        require(bytes(legalName).length > 0, "ERC8004: empty legal name");

        bytes32 idHash = keccak256(abi.encodePacked(identifier));
        address existing = _identifierToAddress[idHash];
        require(existing == address(0) || existing == msg.sender, "ERC8004: identifier already claimed");

        // Release old identifier if changing
        if (bytes(_payees[msg.sender].identifier).length > 0) {
            bytes32 oldHash = keccak256(abi.encodePacked(_payees[msg.sender].identifier));
            if (oldHash != idHash) {
                delete _identifierToAddress[oldHash];
            }
        }

        _identifierToAddress[idHash] = msg.sender;

        _payees[msg.sender] = PayeeIdentity({
            identifier: identifier,
            legalName: legalName,
            metadataURI: metadataURI,
            status: VerificationStatus.PENDING,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp,
            verifier: address(0)
        });

        emit PayeeRegistered(msg.sender, identifier, legalName);
    }

    /**
     * @notice Allows an authorized verifier to set or change a payee's verification status.
     */
    function verifyPayee(address payee, VerificationStatus status) external override onlyVerifier {
        require(payee != address(0), "ERC8004: zero address payee");
        require(bytes(_payees[payee].identifier).length > 0, "ERC8004: payee not registered");

        _payees[payee].status = status;
        _payees[payee].updatedAt = block.timestamp;
        _payees[payee].verifier = msg.sender;

        emit PayeeVerified(payee, msg.sender, status);
    }

    /**
     * @notice Revokes a payee's verified status with an audit reason.
     */
    function revokePayee(address payee, string calldata reason) external override onlyVerifier {
        require(payee != address(0), "ERC8004: zero address payee");
        _payees[payee].status = VerificationStatus.REVOKED;
        _payees[payee].updatedAt = block.timestamp;
        _payees[payee].verifier = msg.sender;

        emit PayeeRevoked(payee, msg.sender, reason);
    }

    function getPayee(address payee) external view override returns (PayeeIdentity memory) {
        return _payees[payee];
    }

    function isVerifiedPayee(address payee) external view override returns (bool) {
        return _payees[payee].status == VerificationStatus.VERIFIED;
    }

    function resolveIdentifier(string calldata identifier) external view override returns (address) {
        bytes32 idHash = keccak256(abi.encodePacked(identifier));
        return _identifierToAddress[idHash];
    }
}
