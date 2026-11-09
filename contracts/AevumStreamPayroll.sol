// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC20.sol";

/**
 * @title AevumStreamPayroll
 * @author Alfredo Alvarado (AevumPay Protocol)
 * @notice Real-time per-second token streaming protocol for continuous payroll and token vesting schedules.
 * Optimized for QDay Aevum Testnet and tUSD8 stablecoin payments.
 */
contract AevumStreamPayroll {
    // Reentrancy guard
    uint256 private _guardStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_guardStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _guardStatus = _ENTERED;
        _;
        _guardStatus = _NOT_ENTERED;
    }

    struct Stream {
        uint256 id;
        address payer;
        address recipient;
        address token;              // e.g. tUSD8
        uint256 deposit;            // Initial deposited amount
        uint256 ratePerSecond;      // Tokens streamed per second
        uint256 startTime;          // Start timestamp
        uint256 stopTime;           // Scheduled completion timestamp
        uint256 remainingBalance;   // Total tokens still residing in contract
        uint256 totalClaimed;       // Withdrawn by recipient so far
        bool isPaused;              // Emergency pause flag
        bool isCancelled;           // Cancel flag
        string title;               // Payroll role or vesting plan identifier
    }

    address public owner;
    uint256 public nextStreamId;
    mapping(uint256 => Stream) public streams;
    mapping(address => uint256[]) private _userStreams;

    event StreamCreated(
        uint256 indexed streamId,
        address indexed payer,
        address indexed recipient,
        uint256 deposit,
        uint256 startTime,
        uint256 stopTime,
        uint256 ratePerSecond,
        string title
    );
    event TokensClaimed(uint256 indexed streamId, address indexed recipient, uint256 amount);
    event StreamCancelled(uint256 indexed streamId, uint256 payerRefund, uint256 recipientBalance);
    event StreamPaused(uint256 indexed streamId);
    event StreamResumed(uint256 indexed streamId);

    modifier onlyOwner() {
        require(msg.sender == owner, "AevumStreamPayroll: not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        _guardStatus = _NOT_ENTERED;
        nextStreamId = 1;
    }

    /**
     * @notice Creates a new streaming payroll or vesting plan.
     * @param recipient Worker or grantee receiving continuous tokens.
     * @param token Payment ERC20 address (tUSD8).
     * @param deposit Total token amount funded.
     * @param startTime Timestamp stream begins.
     * @param stopTime Timestamp stream ends.
     * @param title Description or job role.
     */
    function createStream(
        address recipient,
        address token,
        uint256 deposit,
        uint256 startTime,
        uint256 stopTime,
        string calldata title
    ) external nonReentrant returns (uint256) {
        require(recipient != address(0), "AevumStreamPayroll: zero recipient");
        require(token != address(0), "AevumStreamPayroll: zero token");
        require(deposit > 0, "AevumStreamPayroll: zero deposit");
        require(startTime >= block.timestamp, "AevumStreamPayroll: past startTime");
        require(stopTime > startTime, "AevumStreamPayroll: invalid stopTime");

        uint256 duration = stopTime - startTime;
        require(duration >= 60, "AevumStreamPayroll: minimum 60s stream");
        require(deposit >= duration, "AevumStreamPayroll: deposit < duration");

        // Exact rate per second integer division
        uint256 ratePerSecond = deposit / duration;
        require(ratePerSecond > 0, "AevumStreamPayroll: zero rate");

        // Adjusted deposit to prevent fractional stroop dust
        uint256 totalAdjusted = ratePerSecond * duration;

        uint256 streamId = nextStreamId++;
        streams[streamId] = Stream({
            id: streamId,
            payer: msg.sender,
            recipient: recipient,
            token: token,
            deposit: totalAdjusted,
            ratePerSecond: ratePerSecond,
            startTime: startTime,
            stopTime: stopTime,
            remainingBalance: totalAdjusted,
            totalClaimed: 0,
            isPaused: false,
            isCancelled: false,
            title: title
        });

        _userStreams[msg.sender].push(streamId);
        _userStreams[recipient].push(streamId);

        _safeTransferFrom(token, msg.sender, address(this), totalAdjusted);

        emit StreamCreated(streamId, msg.sender, recipient, totalAdjusted, startTime, stopTime, ratePerSecond, title);
        return streamId;
    }

    /**
     * @notice Computes vested amount accrued by recipient up to current block.timestamp.
     */
    function vestedBalanceOf(uint256 streamId) public view returns (uint256) {
        Stream storage s = streams[streamId];
        if (block.timestamp <= s.startTime) {
            return 0;
        }

        uint256 effectiveCurrentTime = block.timestamp > s.stopTime ? s.stopTime : block.timestamp;
        uint256 elapsed = effectiveCurrentTime - s.startTime;
        return elapsed * s.ratePerSecond;
    }

    /**
     * @notice Computes available balance that recipient can withdraw immediately.
     */
    function availableBalance(uint256 streamId) public view returns (uint256) {
        Stream storage s = streams[streamId];
        if (s.isCancelled) {
            return s.remainingBalance;
        }
        uint256 vested = vestedBalanceOf(streamId);
        if (vested <= s.totalClaimed) {
            return 0;
        }
        return vested - s.totalClaimed;
    }

    /**
     * @notice Recipient withdraws all currently accrued vested tokens.
     */
    function claim(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        require(msg.sender == s.recipient || msg.sender == s.payer, "AevumStreamPayroll: unauthorized caller");
        require(!s.isPaused, "AevumStreamPayroll: stream is paused");

        uint256 claimable = availableBalance(streamId);
        require(claimable > 0, "AevumStreamPayroll: zero claimable");
        require(claimable <= s.remainingBalance, "AevumStreamPayroll: exceeds balance");

        s.totalClaimed += claimable;
        s.remainingBalance -= claimable;

        _safeTransfer(s.token, s.recipient, claimable);

        emit TokensClaimed(streamId, s.recipient, claimable);
    }

    /**
     * @notice Payer cancels stream: accrued tokens stay reserved for recipient, unaccrued tokens refunded to payer.
     */
    function cancelStream(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        require(msg.sender == s.payer || msg.sender == owner, "AevumStreamPayroll: unauthorized cancel");
        require(!s.isCancelled, "AevumStreamPayroll: already cancelled");

        uint256 vested = vestedBalanceOf(streamId);
        uint256 recipientOwed = vested > s.totalClaimed ? (vested - s.totalClaimed) : 0;
        uint256 payerRefund = s.remainingBalance > recipientOwed ? (s.remainingBalance - recipientOwed) : 0;

        s.isCancelled = true;
        s.remainingBalance = recipientOwed;

        if (payerRefund > 0) {
            _safeTransfer(s.token, s.payer, payerRefund);
        }

        emit StreamCancelled(streamId, payerRefund, recipientOwed);
    }

    function getUserStreams(address user) external view returns (uint256[] memory) {
        return _userStreams[user];
    }

    // --- Safe ERC20 Helpers ---
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumStreamPayroll: transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AevumStreamPayroll: transferFrom failed");
    }
}
