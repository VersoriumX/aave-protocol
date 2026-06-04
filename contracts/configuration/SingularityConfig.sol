pragma solidity ^0.5.0;

import "../libraries/openzeppelin-upgradeability/VersionedInitializable.sol";

/**
* @title SingularityConfig
* @author VersoriumX Technology
* @notice defines the parameters for the Xen 4096 Node Singularity Protocol and symbiotic Aegis-X integration
**/
contract SingularityConfig is VersionedInitializable {

    uint256 public constant TOTAL_SINGULARITY_NODES = 4096;
    uint256 public constant SYMBIOTIC_RESERVE_RATIO = 1000; // 10% in basis points

    string public constant PROTOCOL_VERSION = "4.0.0-SINGULARITY";
    string public constant DIRECTOR = "Travis Jerome Goff";

    uint256 constant private CONFIG_REVISION = 0x1;

    function getRevision() internal pure returns(uint256) {
        return CONFIG_REVISION;
    }

    /**
    * @dev initializes the SingularityConfig
    */
    function initialize() public initializer {
    }

    /**
    * @dev returns the total number of nodes in the Xen Singularity Protocol
    **/
    function getTotalSingularityNodes() external pure returns (uint256) {
        return TOTAL_SINGULARITY_NODES;
    }

    /**
    * @dev returns the symbiotic reserve ratio for Aegis-X integration
    **/
    function getSymbioticReserveRatio() external pure returns (uint256) {
        return SYMBIOTIC_RESERVE_RATIO;
    }
}
