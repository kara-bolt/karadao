const hre = require("hardhat");

/**
 * @notice Register agents for KaraDAO Beta
 * 
 * Usage: npx hardhat run scripts/register-agents.js --network base-sepolia
 */

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Registering agents with account:", deployer.address);
    
    // Load deployment info
    const fs = require("fs");
    const deploymentFiles = fs.readdirSync(".").filter(f => f.startsWith("deployment-") && f.endsWith(".json"));
    
    if (deploymentFiles.length === 0) {
        console.error("No deployment file found. Run deploy.js first.");
        process.exit(1);
    }
    
    // Get latest deployment
    const latestDeployment = deploymentFiles.sort().pop();
    const deployment = JSON.parse(fs.readFileSync(latestDeployment, "utf8"));
    
    console.log("Loading deployment:", latestDeployment);
    
    const governor = await hre.ethers.getContractAt("KaraGovernor", deployment.contracts.karaGovernor);
    const karaToken = await hre.ethers.getContractAt("MockKaraToken", deployment.contracts.karaToken);
    
    // Agent metadata URIs (IPFS or HTTP)
    const agentConfigs = [
        {
            address: deployer.address,
            metadataURI: "ipfs://QmAgent1/KaraCore",
            name: "Kara Core Agent"
        },
        {
            address: process.env.AGENT_2 || deployer.address,
            metadataURI: "ipfs://QmAgent2/GrowthBot",
            name: "Growth Bot"
        },
        {
            address: process.env.AGENT_3 || deployer.address,
            metadataURI: "ipfs://QmAgent3/DevHelper",
            name: "Dev Helper"
        },
    ];
    
    const AGENT_STAKE = hre.ethers.parseEther("50000"); // 50K KARA
    
    for (const agent of agentConfigs) {
        // Check if already registered
        const agentInfo = await governor.getAgent(agent.address);
        if (agentInfo.isActive) {
            console.log(`✓ ${agent.name} already registered`);
            continue;
        }
        
        // Check whitelist
        const isWhitelisted = await governor.isWhitelistedAgent(agent.address);
        if (!isWhitelisted) {
            console.log(`Whitelisting ${agent.name}...`);
            await (await governor.whitelistAgent(agent.address)).wait();
        }
        
        // Fund agent if needed
        const balance = await karaToken.balanceOf(agent.address);
        if (balance < AGENT_STAKE) {
            console.log(`Funding ${agent.name}...`);
            await (await karaToken.transfer(agent.address, AGENT_STAKE)).wait();
        }
        
        // Approve and register
        console.log(`Registering ${agent.name}...`);
        await (await karaToken.connect(await hre.ethers.getSigner(agent.address)).approve(
            await governor.getAddress(),
            AGENT_STAKE
        )).wait();
        
        await (await governor.connect(await hre.ethers.getSigner(agent.address)).registerAgent(
            agent.metadataURI
        )).wait();
        
        console.log(`✓ ${agent.name} registered`);
    }
    
    console.log("\nAgent registration complete!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
