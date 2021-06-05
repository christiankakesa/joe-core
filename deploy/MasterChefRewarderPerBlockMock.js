// Deploy for testing of MasterChefJoeV2
module.exports = async function ({ getNamedAccounts, deployments }) {
  const { deploy } = deployments;

  const { deployer } = await getNamedAccounts();

  const sushi = await ethers.getContract("SushiToken");
  const mcv1 = await ethers.getContract("MasterChef");
  const mcv2 = await ethers.getContract("MasterChefJoeV2");
  const lpTokenAddress = "0xbf21027fbf3e6fff156e9f2464881898e4672713"; // WAVAX-USDT on Rinkeby

  await deploy("ERC20Mock", {
    from: deployer,
    args: ["DummyToken", "DUMMY", "1"],
    log: true,
    deterministicDeployment: false,
  });
  const dummyToken = await ethers.getContract("ERC20Mock");

  await deploy("MasterChefRewarderPerBlockMock", {
    from: deployer,
    args: [
      sushi.address,
      lpTokenAddress,
      "100000000000000000000",
      0,
      mcv1.address,
      mcv2.address,
    ],
    gasLmit: 22000000000,
    log: true,
    deterministicDeployment: false,
  });
  const rewarder = await ethers.getContract("MasterChefRewarderPerBlockMock");

  await (await mcv1.add("100", dummyToken.address, true)).wait();
  await dummyToken.approve(rewarder.address, "1");
  await rewarder.init(dummyToken.address, {
    gasLimit: 245000,
  });
};

module.exports.tags = ["MasterChefRewarderPerBlockMock"];
module.exports.dependencies = ["SushiToken", "MasterChef", "MasterChefJoeV2"];
