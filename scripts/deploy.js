const hre = require("hardhat");
const fs = require("fs");

/**
 * @notice Deploy KaraDAO Phase 1 contracts to Base Sepolia
 */

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying KaraDAO Phase 1 with account:", deployer.address);
    
    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log("Account balance:", hre.ethers.formatEther(balance), "ETH");
    
    // Configuration
    const SAM_ADDRESS = process.env.SAM_ADDRESS || deployer.address;
    const KARA_TOKEN_ADDRESS = process.env.KARA_TOKEN_ADDRESS;
    
    let karaToken;
    
    // Deploy or use existing KARA token
    if (KARA_TOKEN_ADDRESS) {
        console.log("Using existing KARA token:", KARA_TOKEN_ADDRESS);
        karaToken = await hre.ethers.getContractAt("MockKaraToken", KARA_TOKEN_ADDRESS);
    } else {
        console.log("\n1. Deploying MockKaraToken...");
        const MockKaraToken = await hre.ethers.getContractFactory("MockKaraToken");
        karaToken = await MockKaraToken.deploy("KARA Token", "KARA", 18);
        await karaToken.waitForDeployment();
        console.log("MockKaraToken deployed to:", await karaToken.getAddress());
    }
    
    const karaTokenAddress = await karaToken.getAddress();
    
    // Deploy KaraSafety first (needed by others)
    console.log("\n2. Deploying KaraSafety...");
    const KaraSafety = await hre.ethers.getContractFactory("KaraSafety");
    const safety = await KaraSafety.deploy(
        hre.ethers.ZeroAddress, // governor placeholder
        hre.ethers.ZeroAddress, // treasury placeholder
        hre.ethers.ZeroAddress, // executor placeholder
        karaTokenAddress,
        SAM_ADDRESS
    );
    await safety.waitForDeployment();
    const safetyAddress = await safety.getAddress();
    console.log("KaraSafety deployed to:", safetyAddress);
    
    // Deploy KaraExecutor
    console.log("\n3. Deploying KaraExecutor...");
    const KaraExecutor = await hre.ethers.getContractFactory("KaraExecutor");
    const executor = await KaraExecutor.deploy(
        hre.ethers.ZeroAddress, // governor placeholder
        safetyAddress,
        hre.ethers.ZeroAddress  // treasury placeholder
    );
    await executor.waitForDeployment();
    const executorAddress = await executor.getAddress();
    console.log("KaraExecutor deployed to:", executorAddress);
    
    // Deploy KaraTreasury
    console.log("\n4. Deploying KaraTreasury...");
    const KaraTreasury = await hre.ethers.getContractFactory("KaraTreasury");
    const treasury = await KaraTreasury.deploy(
        karaTokenAddress,
        hre.ethers.ZeroAddress, // governor placeholder
        safetyAddress
    );
    await treasury.waitForDeployment();
    const treasuryAddress = await treasury.getAddress();
    console.log("KaraTreasury deployed to:", treasuryAddress);
    
    // Deploy KaraGovernor (the main contract)
    console.log("\n5. Deploying KaraGovernor...");
    const KaraGovernor = await hre.ethers.getContractFactory("KaraGovernor");
    const governor = await KaraGovernor.deploy(
        karaTokenAddress,
        safetyAddress,
        executorAddress
    );
    await governor.waitForDeployment();
    const governorAddress = await governor.getAddress();
    console.log("KaraGovernor deployed to:", governorAddress);
    
    // Update contract references
    console.log("\n6. Updating contract references...");
    
    await (await safety.updateContracts(
        governorAddress,
        treasuryAddress,
        executorAddress,
        karaTokenAddress
    )).wait();
    console.log("✓ KaraSafety updated");
    
    await (await executor.updateContracts(
        governorAddress,
        safetyAddress,
        treasuryAddress
    )).wait();
    console.log("✓ KaraExecutor updated");
    
    await (await treasury.updateContracts(
        governorAddress,
        safetyAddress
    )).wait();
    console.log("✓ KaraTreasury updated");
    
    // Whitelist initial agents for Beta
    console.log("\n7. Whitelisting initial Beta agents...");
    const initialAgents = process.env.INITIAL_AGENTS 
        ? process.env.INITIAL_AGENTS.split(",") 
        : [deployer.address];
    
    for (const agent of initialAgents) {
        if (agent && agent !== hre.ethers.ZeroAddress) {
            await (await governor.whitelistAgent(agent)).wait();
            console.log("✓ Whitelisted:", agent);
        }
    }
    
    // Fund agents with KARA for registration
    console.log("\n8. Funding agents for registration...");
    const AGENT_STAKE = hre.ethers.parseEther("50000"); // 50K KARA
    for (const agent of initialAgents) {
        if (agent && agent !== hre.ethers.ZeroAddress) {
            const currentBalance = await karaToken.balanceOf(agent);
            if (currentBalance < AGENT_STAKE) {
                await (await karaToken.transfer(agent, AGENT_STAKE)).wait();
                console.log("✓ Funded:", agent, "with 50K KARA");
            }
        }
    }
    
    // Summary
    console.log("\n" + "=".repeat(60));
    console.log("KaraDAO Phase 1 Deployment Complete!");
    console.log("=".repeat(60));
    console.log("\nContract Addresses:");
    console.log("  KARA Token:", karaTokenAddress);
    console.log("  KaraSafety:", safetyAddress);
    console.log("  KaraExecutor:", executorAddress);
    console.log("  KaraTreasury:", treasuryAddress);
    console.log("  KaraGovernor:", governorAddress);
    console.log("\nConfiguration:");
    console.log("  Sam's Address:", SAM_ADDRESS);
    console.log("  Beta Mode: Enabled (10 agents max)");
    console.log("  Active Tier: INFO only (30s cycles)");
    console.log("\nNext Steps:");
    console.log("  1. Agents must call registerAgent() to activate");
    console.log("  2. Stakers can stake KARA for voting power");
    console.log("  3. Submit proposals through registered agents");
    console.log("=".repeat(60));
    
    // Save deployment info
    const deploymentInfo = {
        network: hre.network.name,
        timestamp: new Date().toISOString(),
        deployer: deployer.address,
        sam: SAM_ADDRESS,
        contracts: {
            karaToken: karaTokenAddress,
            karaSafety: safetyAddress,
            karaExecutor: executorAddress,
            karaTreasury: treasuryAddress,
            karaGovernor: governorAddress,
        },
        initialAgents: initialAgents.filter(a => a && a !== hre.ethers.ZeroAddress),
    };
    
    fs.writeFileSync(
        `deployment-${hre.network.name}-${Date.now()}.json`,
        JSON.stringify(deploymentInfo, null, 2)
    );
    
    return deploymentInfo;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
