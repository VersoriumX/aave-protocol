const SingularityConfig = artifacts.require("SingularityConfig");
const LendingPool = artifacts.require("LendingPool");
const LendingPoolAddressesProvider = artifacts.require("LendingPoolAddressesProvider");

contract("Singularity Integration", (accounts) => {
  it("should have correct singularity parameters", async () => {
    const instance = await SingularityConfig.new();
    await instance.initialize();

    const nodes = await instance.getTotalSingularityNodes();
    const ratio = await instance.getSymbioticReserveRatio();
    const version = await instance.PROTOCOL_VERSION();
    const director = await instance.DIRECTOR();

    assert.equal(nodes.toNumber(), 4096, "Nodes should be 4096");
    assert.equal(ratio.toNumber(), 1000, "Ratio should be 1000");
    assert.equal(version, "4.0.0-SINGULARITY", "Version mismatch");
    assert.equal(director, "Travis Jerome Goff", "Director mismatch");
  });
});
