const { ethers, upgrades } = require("hardhat");
const { getContracts } = require("./getContracts.js");

async function createOrder() {
  const getContractsInstances = await getContracts();
  const { signer, paycrestInstance, DERC20_Contract_Instance } =
    getContractsInstances;
    
  const amount = ethers.utils.parseUnits("0.1", 15);

  const messageHash =
    "0xa3c6bfc43a5f2297001a72039b835698bae96310babf9ff34acc52ad530316f37b961cdf6b119f9422a424b9ad4ac949e282c276131fa7820535a01eb7703cd76350a190e1b6ee4ecc84f6a0f7d090b52e1f565319af139a557fab64b027427e1812576dbfd6c5a2e95166c9a0bc02e967a45be472259572e166758c7865cdc24255f200de23f84f1ac1cc8035b1";

  await paycrestInstance.createOrder(
    DERC20_Contract_Instance.address,
    amount,
    ethers.utils.formatBytes32String("FBNINGLA"),
    970,
    signer.address,
    0,
    signer.address,
    messageHash.toString()
  );
}

createOrder();
