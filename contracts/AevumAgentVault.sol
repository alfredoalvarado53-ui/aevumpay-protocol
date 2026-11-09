// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC8004.sol";

/**
 * @title AevumAgentVault
 * @author Alfredo Alvarado (AevumPay Protocol)
 * @notice Session-Scoped AI Agent Payment Vault for Autonomous On-Chain Commerce on QDay Aevum Testnet.
 * Provides granular spending quotas, daily limits, session expiry, and Confirmation of Payee (ERC-8004) enforcement.
 */
contract AevumAgentVault {
    struct AgentPolicy {
        bool isActive;
        uint256 perTxLimit;         // Maximum allowed per single payment
        uint256 dailyLimit;         // Maximum allowed per 24-hour window
        uint256 spentInCurrentWindow;
        uint256 currentWindowStart;
        uint256 validUntil;         // Expiration timestamp
        bool enforceVerifiedPayee;  // Only permit payments to ERC-8004 verified addresses
    }

    address public owner;
    IERC8004 public copRegistry;

    // Agent address => Policy
    mapping(address => AgentPolicy) public agentPolicies;

    // Track supported tokens (e.g. tUSD8)
    mapping(address => bool) public supportedTokens;

    event AgentPolicyConfigured(
        address indexed agent,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 validUntil,
        bool enforceVerifiedPayee
    );
    event AgentPaymentExecuted(
        address indexed agent,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        string purpose
    );
    event AgentRevoked(address indexed agent);
    event VaultDeposited(address indexed token, address indexed sender, uint256 amount);
    event VaultWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "AevumAgentVault: not owner");
        _;
    }

    constructor(address _copRegistry) {
        owner = msg.sender;
        if (_copRegistry != address(0)) {
            copRegistry = IERC8004(_copRegistry);
        }
    }

    function setCopRegistry(address _copRegistry) external onlyOwner {
        copRegistry = IERC8004(_copRegistry);
    }

    function setSupportedToken(address token, bool isSupported) external onlyOwner {
        supportedTokens[token] = isSupported;
    }

    /**
     * @notice Provisions a delegated session key for an autonomous AI Agent.
     */
    function configureAgent(
        address agent,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 durationSeconds,
        bool enforceVerifiedPayee
    ) external onlyOwner {
        require(agent != address(0), "AevumAgentVault: zero agent address");
        require(dailyLimit >= perTxLimit, "AevumAgentVault: daily limit < perTxLimit");

        agentPolicies[agent] = AgentPolicy({
            isActive: true,
            perTxLimit: perTxLimit,
            dailyLimit: dailyLimit,
            spentInCurrentWindow: 0,
            currentWindowStart: block.timestamp,
            validUntil: block.timestamp + durationSeconds,
            enforceVerifiedPayee: enforceVerifiedPayee
        });

        emit AgentPolicyConfigured(agent, perTxLimit, dailyLimit, block.timestamp + durationSeconds, enforceVerifiedPayee);
    }

    /**
     * @notice Revokes an AI Agent's active session key immediately.
     */
    function revokeAgent(address agent) external onlyOwner {
        agentPolicies[agent].isActive = false;
        emit AgentRevoked(agent);
    }

    /**
     * @notice Autonomous execution point called by an AI Agent.
     * Evaluates session validity, per-transaction budget, daily rolling limits, and ERC-8004 payee status.
     */
    function executeAgentPayment(
        address token,
        address recipient,
        uint256 amount,
        string calldata purpose
    ) external {
        AgentPolicy storage policy = agentPolicies[msg.sender];
        require(policy.isActive, "AevumAgentVault: agent inactive");
        require(block.timestamp <= policy.validUntil, "AevumAgentVault: session expired");
        require(amount <= policy.perTxLimit, "AevumAgentVault: exceeds per-tx limit");

        // Refresh 24h rolling window if elapsed
        if (block.timestamp >= policy.currentWindowStart + 1 days) {
            policy.currentWindowStart = block.timestamp;
            policy.spentInCurrentWindow = 0;
        }

        require(policy.spentInCurrentWindow + amount <= policy.dailyLimit, "AevumAgentVault: exceeds 24h daily quota");

        // Enforce Confirmation of Payee verification if mandated by policy
        if (policy.enforceVerifiedPayee && address(copRegistry) != address(0)) {
            require(copRegistry.isVerifiedPayee(recipient), "AevumAgentVault: recipient not verified under ERC-8004");
        }

        policy.spentInCurrentWindow += amount;

        _safeTransfer(token, recipient, amount);

        emit AgentPaymentExecuted(msg.sender, token, recipient, amount, purpose);
    }

    /**
     * @notice Owner deposits tokens into the vault.
     */
    function deposit(address token, uint256 amount) external {
        _safeTransferFrom(token, msg.sender, address(this), amount);
        emit VaultDeposited(token, msg.sender, amount);
    }

    /**
     * @notice Owner withdraws funds from the vault.
     */
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        _safeTransfer(token, to, amount);
        emit VaultWithdrawn(token, to, amount);
    }

    function getVaultBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // --- Safe ERC20 Helpers ---
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumAgentVault: transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumAgentVault: transferFrom failed");
    }
}
