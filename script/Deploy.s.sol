// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../contracts/KaraGovernor.sol";
import "../contracts/KaraExecutor.sol";
import "../contracts/KaraTreasury.sol";
import "../contracts/KaraSafety.sol";
import "../contracts/MockKaraToken.sol";

/**
 * @title DeployKaraDAO
 * @notice Deployment script for KaraDAO Phase 1 Beta
 * @dev Deploys to Base Sepolia testnet
 */
contract DeployKaraDAO is Script {
    // Configuration
    address public sam = vm.envAddress("SAM_ADDRESS"); // Sam's address for emergency controls
    
    // Contract instances
    MockKaraToken public karaToken;
    KaraGovernor public governor;
    KaraExecutor public executor;
    KaraTreasury public treasury;
    KaraSafety public safety;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("Starting KaraDAO Phase 1 Beta deployment...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Sam (emergency control):", sam);
        
        // Step 1: Deploy Mock KARA Token (for testing - replace with real token for mainnet)
        console.log("\n1. Deploying Mock KARA Token...");
        karaToken = new MockKaraToken("KARA Token", "KARA", 18);
        console.log("   MockKaraToken deployed at:", address(karaToken));
        
        // Step 2: Deploy KaraSafety (no dependencies needed for constructor)
        console.log("\n2. Deploying KaraSafety...");
        safety = new KaraSafety(
            address(0), // governor - will update later
            address(0), // treasury - will update later
            address(0), // executor - will update later
            address(karaToken),
            sam
        );
        console.log("   KaraSafety deployed at:", address(safety));
        
        // Step 3: Deploy KaraTreasury
        console.log("\n3. Deploying KaraTreasury...");
        treasury = new KaraTreasury(
            address(karaToken),
            address(0), // governor - will update later
            address(safety)
        );
        console.log("   KaraTreasury deployed at:", address(treasury));
        
        // Step 4: Deploy KaraExecutor
        console.log("\n4. Deploying KaraExecutor...");
        executor = new KaraExecutor(
            address(0), // governor - will update later
            address(safety),
            address(treasury)
        );
        console.log("   KaraExecutor deployed at:", address(executor));
        
        // Step 5: Deploy KaraGovernor
        console.log("\n5. Deploying KaraGovernor...");
        governor = new KaraGovernor(
            address(karaToken),
            address(safety),
            address(executor)
        );
        console.log("   KaraGovernor deployed at:", address(governor));
        
        // Step 6: Update contract references to break circular dependencies
        console.log("\n6. Updating contract references...");
        
        safety.updateContracts(
            address(governor),
            address(treasury),
            address(executor),
            address(karaToken)
        );
        console.log("   Safety contract references updated");
        
        treasury.updateContracts(address(governor), address(safety));
        console.log("   Treasury contract references updated");
        
        executor.updateContracts(address(governor), address(safety), address(treasury));
        console.log("   Executor contract references updated");
        
        governor.setTreasury(address(treasury));
        console.log("   Governor treasury reference set");
        
        // Step 7: Initial configuration
        console.log("\n7. Configuring Beta settings...");
        
        // INFO tier is already active by default
        console.log("   INFO tier (30s cycles): ACTIVE");
        console.log("   ACTION, FUNDS, CRITICAL tiers: INACTIVE (Phase 1)");
        
        // Step 8: Add initial guardians
        address initialGuardian = vm.addr(deployerPrivateKey);
        safety.addGuardian(initialGuardian);
        console.log("   Added initial guardian:", initialGuardian);
        
        vm.stopBroadcast();
        
        // Print deployment summary
        console.log("\n========================================");
        console.log("KaraDAO Phase 1 Beta Deployment Complete!");
        console.log("========================================");
        console.log("Network: Base Sepolia");
        console.log("");
        console.log("Contract Addresses:");
        console.log("  MockKaraToken: ", address(karaToken));
        console.log("  KaraGovernor:  ", address(governor));
        console.log("  KaraExecutor:  ", address(executor));
        console.log("  KaraTreasury:  ", address(treasury));
        console.log("  KaraSafety:    ", address(safety));
        console.log("");
        console.log("Configuration:");
        console.log("  Sam (emergency):    ", sam);
        console.log("  Initial guardian:   ", initialGuardian);
        console.log("  Beta mode:          ENABLED (whitelist required)");
        console.log("  Max beta agents:    10");
        console.log("  Agent stake req:    50,000 KARA");
        console.log("  INFO tier:          30s cycles, 50%+1 threshold");
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Whitelist up to 10 agent addresses");
        console.log("  2. Agents register with 50K KARA stake");
        console.log("  3. Stakers deposit KARA for voting power");
        console.log("  4. Begin 30-second governance cycles!");
        console.log("========================================");
    }
}

/**
 * @title WhitelistAgents
 * @notice Script to whitelist agents for Beta
 */
contract WhitelistAgents is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        
        // Agent addresses to whitelist (up to 10 for Beta)
        address[] memory agents = vm.envAddressArray("AGENT_ADDRESSES");
        
        vm.startBroadcast(deployerPrivateKey);
        
        KaraGovernor governor = KaraGovernor(governorAddress);
        
        console.log("Whitelisting", agents.length, "agents for Beta...");
        
        for (uint i = 0; i < agents.length; i++) {
            governor.whitelistAgent(agents[i]);
            console.log("  Whitelisted:", agents[i]);
        }
        
        vm.stopBroadcast();
        
        console.log("Done!");
    }
}

/**
 * @title RegisterAsAgent
 * @notice Script for agents to register
 */
contract RegisterAsAgent is Script {
    function run() external {
        uint256 agentPrivateKey = vm.envUint("PRIVATE_KEY");
        address governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        
        string memory metadataURI = vm.envString("METADATA_URI");
        
        vm.startBroadcast(agentPrivateKey);
        
        MockKaraToken token = MockKaraToken(tokenAddress);
        KaraGovernor governor = KaraGovernor(governorAddress);
        
        // Approve and register
        uint256 stakeAmount = 50_000 * 10**18;
        token.approve(governorAddress, stakeAmount);
        governor.registerAgent(metadataURI);
        
        vm.stopBroadcast();
        
        console.log("Agent registered!");
        console.log("  Agent:", vm.addr(agentPrivateKey));
        console.log("  Staked:", stakeAmount);
    }
}