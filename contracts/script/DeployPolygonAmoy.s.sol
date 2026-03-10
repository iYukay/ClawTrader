// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../TestUSDC.sol";
import "../TestBTC.sol";
import "../TestETH.sol";
import "../TestSOL.sol";
import "../ClawToken.sol";
import "../SimpleDEX.sol";
import "../AgentVaultV2.sol";
import "../VaultB.sol";
import "../AgentFactory.sol";
import "../BettingEscrow.sol";

/**
 * @title DeployPolygonAmoy
 * @dev Deploy all ClawTrader contracts to Polygon Amoy testnet
 *
 * Run with:
 *   forge script contracts/script/DeployPolygonAmoy.s.sol \
 *     --rpc-url https://polygon-amoy.drpc.org \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast -vvvv
 */
contract DeployPolygonAmoy is Script {
    // Initial prices in USDC (6 decimals) — live approximate values
    uint256 constant BTC_PRICE  = 97_000 * 1e6;  // $97,000
    uint256 constant ETH_PRICE  = 2_800  * 1e6;  // $2,800
    uint256 constant SOL_PRICE  = 185    * 1e6;  // $185

    // Liquidity to seed into SimpleDEX
    uint256 constant DEX_USDC_SEED = 100_000 * 1e6;    // 100k USDC
    uint256 constant DEX_BTC_SEED  = 1       * 1e8;    // 1 BTC
    uint256 constant DEX_ETH_SEED  = 35      * 1e18;   // 35 ETH
    uint256 constant DEX_SOL_SEED  = 540     * 1e9;    // 540 SOL

    // USDC to fund VaultB (profit distribution reserve) — 1M USDC
    uint256 constant VAULT_B_SEED  = 1_000_000 * 1e6;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        console.log("=== ClawTrader Polygon Amoy Deployment ===");
        console.log("Deployer:", deployer);

        // ── 1. TEST TOKENS ────────────────────────────────────────────────
        console.log("\n[1/10] Deploying TestUSDC...");
        TestUSDC usdc = new TestUSDC();
        console.log("TestUSDC:      ", address(usdc));

        console.log("[2/10] Deploying TestBTC...");
        TestBTC tBTC = new TestBTC();
        console.log("TestBTC:       ", address(tBTC));

        console.log("[3/10] Deploying TestETH...");
        TestETH tETH = new TestETH();
        console.log("TestETH:       ", address(tETH));

        console.log("[4/10] Deploying TestSOL...");
        TestSOL tSOL = new TestSOL();
        console.log("TestSOL:       ", address(tSOL));

        // ── 2. CLAW TOKEN ─────────────────────────────────────────────────
        console.log("[5/10] Deploying ClawToken...");
        ClawToken clawToken = new ClawToken();
        console.log("ClawToken:     ", address(clawToken));

        // ── 3. SIMPLE DEX ─────────────────────────────────────────────────
        console.log("[6/10] Deploying SimpleDEX...");
        SimpleDEX dex = new SimpleDEX(address(usdc));
        console.log("SimpleDEX:     ", address(dex));

        // Register tokens in DEX with initial oracle prices
        dex.addToken(address(tBTC), 8,  BTC_PRICE);
        dex.addToken(address(tETH), 18, ETH_PRICE);
        dex.addToken(address(tSOL), 9,  SOL_PRICE);

        // Seed USDC liquidity into DEX
        usdc.approve(address(dex), DEX_USDC_SEED);
        dex.addLiquidity(address(usdc), DEX_USDC_SEED);

        // Seed token liquidity into DEX
        tBTC.approve(address(dex), DEX_BTC_SEED);
        dex.addLiquidity(address(tBTC), DEX_BTC_SEED);

        tETH.approve(address(dex), DEX_ETH_SEED);
        dex.addLiquidity(address(tETH), DEX_ETH_SEED);

        tSOL.approve(address(dex), DEX_SOL_SEED);
        dex.addLiquidity(address(tSOL), DEX_SOL_SEED);

        console.log("SimpleDEX seeded with USDC + tBTC + tETH + tSOL");

        // ── 4. AGENT VAULT V2 ─────────────────────────────────────────────
        console.log("[7/10] Deploying AgentVaultV2...");
        AgentVaultV2 vault = new AgentVaultV2(address(usdc), address(dex));
        console.log("AgentVaultV2:  ", address(vault));

        // Register supported trading tokens in Vault
        vault.addSupportedToken(address(tBTC));
        vault.addSupportedToken(address(tETH));
        vault.addSupportedToken(address(tSOL));

        // The deployer private key IS the trading server key, so deployer = operator
        vault.setOperator(deployer);
        console.log("AgentVaultV2 operator = deployer (trading server wallet)");

        // ── 5. VAULT B ────────────────────────────────────────────────────
        console.log("[8/10] Deploying VaultB...");
        VaultB vaultB = new VaultB(address(usdc), address(vault));
        console.log("VaultB:        ", address(vaultB));

        // Seed VaultB with profit reserve
        usdc.approve(address(vaultB), VAULT_B_SEED);
        vaultB.fund(VAULT_B_SEED);
        console.log("VaultB seeded with 1M USDC");

        // ── 6. AGENT FACTORY ──────────────────────────────────────────────
        console.log("[9/10] Deploying AgentFactory...");
        AgentFactory factory = new AgentFactory();
        console.log("AgentFactory:  ", address(factory));

        // ── 7. BETTING ESCROW ─────────────────────────────────────────────
        // BettingEscrow uses ClawToken (CLAW) for bets
        console.log("[10/10] Deploying BettingEscrow...");
        BettingEscrow escrow = new BettingEscrow(address(clawToken));
        console.log("BettingEscrow: ", address(escrow));

        vm.stopBroadcast();

        // ── SUMMARY ───────────────────────────────────────────────────────
        console.log("\n==========================================");
        console.log("=== DEPLOYMENT COMPLETE -- Polygon Amoy ===");
        console.log("==========================================");
        console.log("Network:        Polygon Amoy (chainId 80002)");
        console.log("Deployer:      ", deployer);
        console.log("------------------------------------------");
        console.log("TestUSDC:      ", address(usdc));
        console.log("TestBTC:       ", address(tBTC));
        console.log("TestETH:       ", address(tETH));
        console.log("TestSOL:       ", address(tSOL));
        console.log("ClawToken:     ", address(clawToken));
        console.log("SimpleDEX:     ", address(dex));
        console.log("AgentVaultV2:  ", address(vault));
        console.log("VaultB:        ", address(vaultB));
        console.log("AgentFactory:  ", address(factory));
        console.log("BettingEscrow: ", address(escrow));
        console.log("==========================================");
    }
}
