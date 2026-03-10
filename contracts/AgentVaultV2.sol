// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ISimpleDEX {
    function buyToken(address tokenOut, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);
    function sellToken(address tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut);
    function getBuyQuote(address tokenOut, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee);
    function getSellQuote(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint256 fee);
}

/**
 * @title AgentVaultV2
 * @dev AI agent vault with real on-chain DEX trading
 *
 * Architecture:
 * - Users deposit USDC to fund their AI agents
 * - Operator (trading server) executes real trades on SimpleDEX using vault USDC
 * - Gas wallet pays MATIC gas for all users — users never need MATIC
 * - Token positions stored in vault, P&L flows back to user's USDC balance
 */
contract AgentVaultV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    ISimpleDEX public dex;
    address public operator;

    // USDC balances: user => agentId => amount (6 decimals)
    mapping(address => mapping(bytes32 => uint256)) public userAgentBalances;

    // Token positions: user => agentId => tokenAddress => amount
    mapping(address => mapping(bytes32 => mapping(address => uint256))) public tokenPositions;

    // Total USDC per agent
    mapping(bytes32 => uint256) public agentTotalBalances;

    // User's registered agents
    mapping(address => bytes32[]) public userAgents;
    mapping(address => mapping(bytes32 => bool)) public userHasAgent;

    // Platform fee: 0.5%
    uint256 public platformFee = 50;
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public collectedFees;

    // Events
    event Deposited(address indexed user, bytes32 indexed agentId, uint256 amount);
    event Withdrawn(address indexed user, bytes32 indexed agentId, uint256 amount);
    event TradeBought(address indexed user, bytes32 indexed agentId, address token, uint256 usdcSpent, uint256 tokensReceived, bytes32 txRef);
    event TradeSold(address indexed user, bytes32 indexed agentId, address token, uint256 tokensSold, uint256 usdcReceived, int256 pnl, bytes32 txRef);
    event OperatorUpdated(address indexed newOperator);
    event DexUpdated(address indexed newDex);

    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == owner(), "Not authorized");
        _;
    }

    constructor(address _usdc, address _dex) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC");
        require(_dex != address(0), "Invalid DEX");
        usdc = IERC20(_usdc);
        dex = ISimpleDEX(_dex);
        operator = msg.sender;
    }

    // ============ User Functions ============

    function deposit(bytes32 agentId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        userAgentBalances[msg.sender][agentId] += amount;
        agentTotalBalances[agentId] += amount;

        if (!userHasAgent[msg.sender][agentId]) {
            userAgents[msg.sender].push(agentId);
            userHasAgent[msg.sender][agentId] = true;
        }

        emit Deposited(msg.sender, agentId, amount);
    }

    function withdraw(bytes32 agentId, uint256 amount) external nonReentrant {
        require(userAgentBalances[msg.sender][agentId] >= amount, "Insufficient USDC balance");
        userAgentBalances[msg.sender][agentId] -= amount;
        agentTotalBalances[agentId] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, agentId, amount);
    }

    // ============ Operator Trading Functions ============

    /**
     * @dev Buy tokens with vault USDC on behalf of a user's agent
     * Gas wallet (operator) pays MATIC — user's USDC pays for the trade
     */
    function operatorBuy(
        bytes32 agentId,
        address user,
        address tokenOut,
        uint256 usdcAmount,
        uint256 minTokens
    ) external onlyOperator nonReentrant returns (uint256 tokensReceived) {
        require(userAgentBalances[user][agentId] >= usdcAmount, "Insufficient agent USDC");
        require(usdcAmount > 0, "Amount must be > 0");

        // Deduct USDC from user's agent balance
        userAgentBalances[user][agentId] -= usdcAmount;
        agentTotalBalances[agentId] -= usdcAmount;

        // Platform fee
        uint256 fee = (usdcAmount * platformFee) / FEE_DENOMINATOR;
        collectedFees += fee;
        uint256 tradeAmount = usdcAmount - fee;

        // Approve DEX and execute real swap
        usdc.approve(address(dex), tradeAmount);
        tokensReceived = dex.buyToken(tokenOut, tradeAmount, minTokens);

        // Store tokens in vault for this user/agent
        tokenPositions[user][agentId][tokenOut] += tokensReceived;

        emit TradeBought(user, agentId, tokenOut, usdcAmount, tokensReceived, blockhash(block.number - 1));
    }

    /**
     * @dev Sell tokens back to USDC on behalf of a user's agent
     */
    function operatorSell(
        bytes32 agentId,
        address user,
        address tokenIn,
        uint256 tokenAmount,
        uint256 minUSDC
    ) external onlyOperator nonReentrant returns (uint256 usdcReceived) {
        require(tokenPositions[user][agentId][tokenIn] >= tokenAmount, "Insufficient token position");
        require(tokenAmount > 0, "Amount must be > 0");

        // Deduct tokens from position
        tokenPositions[user][agentId][tokenIn] -= tokenAmount;

        // Approve DEX and execute real swap
        IERC20(tokenIn).approve(address(dex), tokenAmount);
        usdcReceived = dex.sellToken(tokenIn, tokenAmount, minUSDC);

        // Credit USDC back to user's agent balance
        userAgentBalances[user][agentId] += usdcReceived;
        agentTotalBalances[agentId] += usdcReceived;

        emit TradeSold(user, agentId, tokenIn, tokenAmount, usdcReceived, 0, blockhash(block.number - 1));
    }

    // ============ View Functions ============

    function getUserAgentBalance(address user, bytes32 agentId) external view returns (uint256) {
        return userAgentBalances[user][agentId];
    }

    function getUserAgents(address user) external view returns (bytes32[] memory) {
        return userAgents[user];
    }

    function getAgentTotalBalance(bytes32 agentId) external view returns (uint256) {
        return agentTotalBalances[agentId];
    }

    function getTokenPosition(address user, bytes32 agentId, address token) external view returns (uint256) {
        return tokenPositions[user][agentId][token];
    }

    // ============ Admin Functions ============

    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    function setDex(address _dex) external onlyOwner {
        dex = ISimpleDEX(_dex);
        emit DexUpdated(_dex);
    }

    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= 200, "Max 2%");
        platformFee = _fee;
    }

    function withdrawFees() external onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        usdc.safeTransfer(owner(), amount);
    }

    // Emergency: withdraw stuck tokens
    function rescueToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
