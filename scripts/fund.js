const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Funding agent with KARA...");
    
    const karaToken = await hre.ethers.getContractAt("MockKaraToken", "0xFa0f86a897Ad2Ad28a78CaAF78e44F6EC2c423C9");
    
    const AGENT_STAKE = hre.ethers.parseEther("50000");
    await (await karaToken.transfer(deployer.address, AGENT_STAKE)).wait();
    
    const balance = await karaToken.balanceOf(deployer.address);
    console.log("KARA Balance:", hre.ethers.formatEther(balance), "KARA");
    console.log("✓ Funded!");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
