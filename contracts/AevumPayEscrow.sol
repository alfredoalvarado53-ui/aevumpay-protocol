// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";
import "./interfaces/IERC8004.sol";

/**
 * @title AevumPayEscrow
 * @author Alfredo Alvarado (AevumPay Protocol)
 * @notice Enterprise Invoice & Milestone Escrow with Confirmation of Payee (ERC-8004) and HTLC Cryptographic Release.
 * Built for QDay Aevum Testnet utilizing the native tUSD8 test stablecoin.
 */
contract AevumPayEscrow {
    // Reentrancy guard state
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    enum EscrowStatus { CREATED, FUNDED, RELEASED, REFUNDED, DISPUTED }

    struct Escrow {
        uint256 id;
        address payer;
        address payee;
        address token;              // e.g. tUSD8 (0x456569838f1d43009A91ebA4263147Afd7233483)
        uint256 amount;             // In token units (6 decimals for tUSD8)
        bytes32 hashLock;           // keccak256(preimage) for cryptographic HTLC release (or bytes32(0))
        uint256 deadline;           // Unix timestamp after which payer can refund if not released
        EscrowStatus status;
        bool requireVerifiedPayee;  // Enforce ERC-8004 Confirmation of Payee verification
        string invoiceRef;          // External reference or IPFS CID
    }

    address public owner;
    address public arbitrator;
    IERC8004 public copRegistry;     // ERC-8004 Confirmation of Payee Registry

    uint256 public nextEscrowId;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256[]) private _userEscrows;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed payer,
        address indexed payee,
        uint256 amount,
        string invoiceRef
    );
    event EscrowFunded(uint256 indexed escrowId, uint256 amount);
    event EscrowReleased(uint256 indexed escrowId, address indexed payee, uint256 amount);
    event EscrowRefunded(uint256 indexed escrowId, address indexed payer, uint256 amount);
    event EscrowDisputed(uint256 indexed escrowId, address indexed initiator);
    event EscrowResolved(uint256 indexed escrowId, address recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "AevumPayEscrow: caller is not the owner");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator || msg.sender == owner, "AevumPayEscrow: caller is not arbitrator");
        _;
    }

    constructor(address _copRegistry, address _arbitrator) {
        owner = msg.sender;
        arbitrator = _arbitrator != address(0) ? _arbitrator : msg.sender;
        if (_copRegistry != address(0)) {
            copRegistry = IERC8004(_copRegistry);
        }
        _status = _NOT_ENTERED;
        nextEscrowId = 1;
    }

    function setCopRegistry(address newRegistry) external onlyOwner {
        copRegistry = IERC8004(newRegistry);
    }

    function setArbitrator(address newArbitrator) external onlyOwner {
        require(newArbitrator != address(0), "AevumPayEscrow: zero address arbitrator");
        arbitrator = newArbitrator;
    }

    /**
     * @notice Creates and immediately funds an invoice milestone escrow.
     * @param payee Intended receiver of the payment.
     * @param token Address of ERC20 payment asset (e.g. tUSD8).
     * @param amount Token amount to lock.
     * @param hashLock Preimage hash for HTLC release (pass 0 if manual release is preferred).
     * @param durationSeconds Lock duration before timeout refund is available.
     * @param requireVerifiedPayee If true, checks ERC-8004 registry to ensure payee is VERIFIED.
     * @param invoiceRef Invoice ID or metadata string.
     */
    function createEscrow(
        address payee,
        address token,
        uint256 amount,
        bytes32 hashLock,
        uint256 durationSeconds,
        bool requireVerifiedPayee,
        string calldata invoiceRef
    ) external nonReentrant returns (uint256) {
        require(payee != address(0), "AevumPayEscrow: zero payee");
        require(token != address(0), "AevumPayEscrow: zero token");
        require(amount > 0, "AevumPayEscrow: zero amount");
        require(durationSeconds >= 60, "AevumPayEscrow: minimum duration 60s");

        // Confirmation of Payee verification check
        if (requireVerifiedPayee && address(copRegistry) != address(0)) {
            require(copRegistry.isVerifiedPayee(payee), "AevumPayEscrow: payee fails ERC-8004 verification");
        }

        uint256 escrowId = nextEscrowId++;
        uint256 deadline = block.timestamp + durationSeconds;

        escrows[escrowId] = Escrow({
            id: escrowId,
            payer: msg.sender,
            payee: payee,
            token: token,
            amount: amount,
            hashLock: hashLock,
            deadline: deadline,
            status: EscrowStatus.FUNDED,
            requireVerifiedPayee: requireVerifiedPayee,
            invoiceRef: invoiceRef
        });

        _userEscrows[msg.sender].push(escrowId);
        _userEscrows[payee].push(escrowId);

        // Safe transfer tokens into escrow contract
        _safeTransferFrom(token, msg.sender, address(this), amount);

        emit EscrowCreated(escrowId, msg.sender, payee, amount, invoiceRef);
        emit EscrowFunded(escrowId, amount);

        return escrowId;
    }

    /**
     * @notice Releases escrowed funds to payee. Callable by payer or arbitrator.
     */
    function release(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.FUNDED, "AevumPayEscrow: not in funded state");
        require(msg.sender == e.payer || msg.sender == arbitrator || msg.sender == owner, "AevumPayEscrow: unauthorized release");

        e.status = EscrowStatus.RELEASED;
        _safeTransfer(e.token, e.payee, e.amount);

        emit EscrowReleased(escrowId, e.payee, e.amount);
    }

    /**
     * @notice Releases escrow using cryptographic preimage (HTLC atomic release).
     * Callable by anyone (including payee or autonomous relayers) providing the correct preimage.
     */
    function releaseWithPreimage(uint256 escrowId, bytes calldata preimage) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.FUNDED, "AevumPayEscrow: not in funded state");
        require(e.hashLock != bytes32(0), "AevumPayEscrow: no hashlock configured");
        require(keccak256(preimage) == e.hashLock, "AevumPayEscrow: invalid preimage");

        e.status = EscrowStatus.RELEASED;
        _safeTransfer(e.token, e.payee, e.amount);

        emit EscrowReleased(escrowId, e.payee, e.amount);
    }

    /**
     * @notice Refunds escrowed tokens to payer if deadline has passed.
     */
    function refundAfterDeadline(uint256 escrowId) external nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.FUNDED, "AevumPayEscrow: not in funded state");
        require(block.timestamp >= e.deadline, "AevumPayEscrow: deadline not reached");
        require(msg.sender == e.payer || msg.sender == arbitrator || msg.sender == owner, "AevumPayEscrow: unauthorized refund");

        e.status = EscrowStatus.REFUNDED;
        _safeTransfer(e.token, e.payer, e.amount);

        emit EscrowRefunded(escrowId, e.payer, e.amount);
    }

    /**
     * @notice Initiates a dispute. Locks escrow until arbitrator resolves.
     */
    function raiseDispute(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.FUNDED, "AevumPayEscrow: not in funded state");
        require(msg.sender == e.payer || msg.sender == e.payee, "AevumPayEscrow: only parties can dispute");

        e.status = EscrowStatus.DISPUTED;
        emit EscrowDisputed(escrowId, msg.sender);
    }

    /**
     * @notice Arbitrator resolution: splits or awards funds to payer or payee.
     */
    function resolveDispute(
        uint256 escrowId,
        uint256 payeeShare,
        uint256 payerShare
    ) external onlyArbitrator nonReentrant {
        Escrow storage e = escrows[escrowId];
        require(e.status == EscrowStatus.DISPUTED, "AevumPayEscrow: not disputed");
        require(payeeShare + payerShare == e.amount, "AevumPayEscrow: shares mismatch amount");

        e.status = EscrowStatus.RELEASED;

        if (payeeShare > 0) {
            _safeTransfer(e.token, e.payee, payeeShare);
        }
        if (payerShare > 0) {
            _safeTransfer(e.token, e.payer, payerShare);
        }

        emit EscrowResolved(escrowId, e.payee, payeeShare);
    }

    function getUserEscrows(address user) external view returns (uint256[] memory) {
        return _userEscrows[user];
    }

    // --- Safe ERC20 Helpers ---
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumPayEscrow: transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumPayEscrow: transferFrom failed");
    }
}
