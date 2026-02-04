const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Setting up Beta agents with account:", deployer.address);
    
    // Contract addresses
    const ADDRESSES = {
        karaToken: "0xFa0f86a897Ad2Ad28a78CaAF78e44F6EC2c423C9",
        karaGovernor: "0xe918d473Ae610aD07c1B62476668F37e3B155602"
    };
    
    const governor = await hre.ethers.getContractAt("KaraGovernor", ADDRESSES.karaGovernor);
    const karaToken = await hre.ethers.getContractAt("MockKaraToken", ADDRESSES.karaToken);
    
    // Whitelist deployer as Beta agent
    console.log("\n1. Whitelisting deployer as Beta agent...");
    await (await governor.whitelistAgent(deployer.address)).wait();
    console.log("✓ Agent whitelisted:", deployer.address);
    
    // Fund with 50K KARA
    console.log("\n2. Funding agent with 50,000 KARA...");
    const AGENT_STAKE = hre.ethers.parseEther("50000");
    await (await karaToken.transfer(deployer.address, AGENT_STAKE)).wait();
    console.log("✓ Funded with 50,000 KARA");
    
    // Check balances
    const karaBalance = await karaToken.balanceOf(deployer.address);
    console.log("\n3. Verifying balances...");
    console.log("   KARA Balance:", hre.ethers.formatEther(karaBalance), "KARA");
    
    // Try to register as agent
    console.log("\n4. Registering as agent delegate...");
    try {
        await (await governor.registerAgent("kara-agent-v1")).wait();
        console.log("✓ Agent registered successfully!");
        
        const agentInfo = await governor.getAgentInfo(deployer.address);
        console.log("   Agent reputation:", agentInfo.reputation.toString());
    } catch (e) {
        console.log("   Registration result:", e.message);
    }
    
    console.log("\n" + "=".repeat(60));
    console.log("Beta agent setup complete!");
    console.log("=".repeat(60));
    console.log("\nAgent Address:", deployer.address);
    console.log("Ready to submit proposals!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
