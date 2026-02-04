const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Updating contract references with account:", deployer.address);
    
    // Contract addresses from deployment
    const ADDRESSES = {
        karaToken: "0xFa0f86a897Ad2Ad28a78CaAF78e44F6EC2c423C9",
        karaSafety: "0x7dc3aA2f6fC7cD3814b0F45a84977a695c43016b",
        karaExecutor: "0x1AAc7d3f23480b52E91A82c6e5a18baB24b554f3",
        karaTreasury: "0x50fc353937D1CBdD8E1e337D025d2f9584c70096",
        karaGovernor: "0xe918d473Ae610aD07c1B62476668F37e3B155602"
    };
    
    // Get contract instances
    const safety = await hre.ethers.getContractAt("KaraSafety", ADDRESSES.karaSafety);
    const executor = await hre.ethers.getContractAt("KaraExecutor", ADDRESSES.karaExecutor);
    const treasury = await hre.ethers.getContractAt("KaraTreasury", ADDRESSES.karaTreasury);
    
    // Update references one by one with delays
    console.log("\nUpdating KaraExecutor...");
    await (await executor.updateContracts(
        ADDRESSES.karaGovernor,
        ADDRESSES.karaSafety,
        ADDRESSES.karaTreasury
    )).wait();
    console.log("✓ KaraExecutor updated");
    
    await new Promise(r => setTimeout(r, 5000));
    
    console.log("\nUpdating KaraTreasury...");
    await (await treasury.updateContracts(
        ADDRESSES.karaGovernor,
        ADDRESSES.karaSafety
    )).wait();
    console.log("✓ KaraTreasury updated");
    
    console.log("\n" + "=".repeat(60));
    console.log("All contract references updated!");
    console.log("=".repeat(60));
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
