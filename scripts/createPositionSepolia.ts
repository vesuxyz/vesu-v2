import { Amount, setup, toU256 } from "../lib";

async function main() {
  // For Sepolia deployment
  const POOL_ADDRESS = "0x6227c13372b8c7b7f38ad1cfe05b5cf515b4e5c596dd05fe8437ab9747b2093";
  const STRK_ADDRESS = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
  const USDC_ADDRESS = "0x0512feac6339ff7889822cb5aa2a86c848e9d392bb0e3e237c008674feed8343";

  // STRK has 18 decimals, USDC has 6 decimals
  const STRK_DECIMALS = 18n;
  const USDC_DECIMALS = 6n;

  try {
  const deployer = await setup("sepolia");

  // Load contracts
  const pool = await deployer.loadContract(POOL_ADDRESS);
  const strk = await deployer.loadContract(STRK_ADDRESS);

  // 10 STRK collateral, 0.1 USDC debt
  const collateralAmount = 10n * 10n ** STRK_DECIMALS;
  const debtAmount = BigInt(0.1 * Number(10n ** USDC_DECIMALS)); // 0.1 USDC = 100000

  console.log("\n=== Creating Position ===");
  console.log("Pool:", POOL_ADDRESS);
  console.log("User:", deployer.owner.address);
  console.log("Collateral:", collateralAmount.toString(), "STRK (10 STRK)");
  console.log("Debt:", debtAmount.toString(), "USDC (0.1 USDC)");

  // Check balances
  console.log("\n=== Checking Balances ===");
  const strkBalance = await strk.balanceOf(deployer.owner.address);
  console.log("STRK Balance:", strkBalance.toString());

  // Approve pool to spend STRK
  console.log("\n=== Approving STRK ===");
  strk.providerOrAccount = deployer.owner;
  const approveResponse = await strk.approve(POOL_ADDRESS, toU256(collateralAmount));
  console.log("Approve tx:", approveResponse.transaction_hash);
  await deployer.waitForTransaction(approveResponse.transaction_hash);
  console.log("Approval confirmed");

  // Call modify_position
  console.log("\n=== Calling modify_position ===");
  pool.providerOrAccount = deployer.owner;
  const response = await pool.modify_position({
    collateral_asset: STRK_ADDRESS,
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