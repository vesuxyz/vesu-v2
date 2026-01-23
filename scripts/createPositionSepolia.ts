import { Amount, setup, toU256 } from "../lib";

async function main() {
  // For Sepolia deployment
  const POOL_ADDRESS = "0x6227c13372b8c7b7f38ad1cfe05b5cf515b4e5c596dd05fe8437ab9747b2093";
  const WBTC_ADDRESS = "0x04861ba938aed21f2cd7740acd3765ac4d2974783a3218367233de0153490cb6";
  const USDC_ADDRESS = "0x0512feac6339ff7889822cb5aa2a86c848e9d392bb0e3e237c008674feed8343";

  // WBTC has 8 decimals, USDC has 6 decimals
  const WBTC_DECIMALS = 8n;
  const USDC_DECIMALS = 6n;

  try {
  const deployer = await setup("sepolia");

  // Load contracts
  const pool = await deployer.loadContract(POOL_ADDRESS);
  const wbtc = await deployer.loadContract(WBTC_ADDRESS);
  const usdc = await deployer.loadContract(USDC_ADDRESS);

  // 1 WBTC collateral, 0.1 USDC debt
  const collateralAmount = 1n * 10n ** WBTC_DECIMALS; // 1 WBTC = 100000000
  const debtAmount = BigInt(0.1 * Number(10n ** USDC_DECIMALS)); // 0.1 USDC = 100000

  console.log("\n=== Creating Position ===");
  console.log("Pool:", POOL_ADDRESS);
  console.log("User:", deployer.owner.address);
  console.log("Collateral:", collateralAmount.toString(), "WBTC (100000000 = 1 WBTC)");
  console.log("Debt:", debtAmount.toString(), "USDC (100000 = 0.1 USDC)");

  // Check balances
  console.log("\n=== Checking Balances ===");
  const wbtcBalance = await wbtc.balanceOf(deployer.owner.address);
  const usdcBalance = await usdc.balanceOf(deployer.owner.address);
  console.log("WBTC Balance:", wbtcBalance.toString());
  console.log("USDC Balance:", usdcBalance.toString());

  // Approve pool to spend WBTC
  console.log("\n=== Approving WBTC ===");
  wbtc.providerOrAccount = deployer.owner;
  const approveResponse = await wbtc.approve(POOL_ADDRESS, toU256(collateralAmount));
  console.log("Approve tx:", approveResponse.transaction_hash);
  await deployer.waitForTransaction(approveResponse.transaction_hash);
  console.log("Approval confirmed");

  // Call modify_position
  console.log("\n=== Calling modify_position ===");
  pool.providerOrAccount = deployer.owner;
  const response = await pool.modify_position({
    collateral_asset: WBTC_ADDRESS,
    debt_asset: USDC_ADDRESS,
    user: deployer.owner.address,
    collateral: Amount({
      amountType: "Delta",
      denomination: "Assets",
      value: collateralAmount,
    }),
    debt: Amount({
      amountType: "Delta",
      denomination: "Assets",
      value: debtAmount,
    }),
  });

  console.log("Transaction hash:", response.transaction_hash);
  console.log("Waiting for confirmation...");

  const receipt = await deployer.waitForTransaction(response.transaction_hash);
  console.log("\n=== Transaction Confirmed ===");
  console.log("Status:", receipt.isSuccess() ? "SUCCESS" : "FAILED");

  if (!receipt.isSuccess()) {
    console.log("Transaction failed");
  } else {
    console.log("\n=== Position Created Successfully ===");
    console.log("View on Starkscan:", `https://sepolia.starkscan.co/tx/${response.transaction_hash}`);
  }
  } catch (error: any) {
    console.error("\n=== Transaction Failed ===");
    if (error.message) {
      console.error("Error message:", error.message);
    }
    if (error.response?.data) {
      console.error("Response data:", JSON.stringify(error.response.data, null, 2));
    }
    console.error("Full error:", error);
    process.exit(1);
  }
}

main();