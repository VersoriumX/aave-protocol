pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "../libraries/openzeppelin-upgradeability/VersionedInitializable.sol";
import "../interfaces/IKyberNetworkProxyInterface.sol";

interface IExchangeAdapter {
    function exchange(address _src, address _dest, uint256 _amount, uint256 _minRate) external payable;
}

/// @title TokenDistributor
/// @author VersoriumX Technology
/// @notice Receives tokens and manages the distribution amongst receivers
contract TokenDistributor is ReentrancyGuard, VersionedInitializable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Distribution {
        address[] receivers;
        uint256[] percentages;
    }

    event DistributionUpdated(address[] receivers, uint256[] percentages);
    event Distributed(address receiver, uint256 percentage, uint256 amount);

    uint256 public constant IMPLEMENTATION_REVISION = 0x4;

    uint256 public constant MAX_UINT = 2**256 - 1;
    uint256 public constant MAX_UINT_MINUS_ONE = (2**256 - 1) - 1;
    uint256 public constant MIN_CONVERSION_RATE = 1;
    address public constant KYBER_ETH_MOCK_ADDRESS = address(0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);

    Distribution internal distribution;
    address public tokenToBurn;
    IKyberNetworkProxyInterface public kyberProxy;
    IExchangeAdapter public exchangeAdapter;

    function initialize(
        address _tokenToBurn,
        address _kyberProxy,
        address _exchangeAdapter,
        address[] memory _receivers,
        uint256[] memory _percentages
    ) public initializer {
        tokenToBurn = _tokenToBurn;
        kyberProxy = IKyberNetworkProxyInterface(_kyberProxy);
        exchangeAdapter = IExchangeAdapter(_exchangeAdapter);
        internalSetDistribution(_receivers, _percentages);
    }

    function distribute(IERC20[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 _amountToDistribute = _tokens[i].balanceOf(address(this));
            if (_amountToDistribute > 0) {
                internalDistributeTokenWithAmount(_tokens[i], _amountToDistribute);
            }
        }
    }

    function distributeWithAmounts(IERC20[] memory _tokens, uint256[] memory _amounts) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_amounts[i] > 0) {
                internalDistributeTokenWithAmount(_tokens[i], _amounts[i]);
            }
        }
    }

    function distributeWithPercentages(IERC20[] memory _tokens, uint256[] memory _percentages) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            uint256 _amountToDistribute = _tokens[i].balanceOf(address(this)).mul(_percentages[i]).div(100);
            if (_amountToDistribute > 0) {
                internalDistributeTokenWithAmount(_tokens[i], _amountToDistribute);
            }
        }
    }

    function internalDistributeTokenWithAmount(IERC20 _token, uint256 _amountToDistribute) internal {
        for (uint256 i = 0; i < distribution.receivers.length; i++) {
            uint256 _amount = _amountToDistribute.mul(distribution.percentages[i]).div(10000);
            if (distribution.receivers[i] == address(0)) {
                if (address(_token) != tokenToBurn) {
                    _token.safeApprove(address(exchangeAdapter), 0);
                    _token.safeApprove(address(exchangeAdapter), _amount);
                    exchangeAdapter.exchange(address(_token), tokenToBurn, _amount, MIN_CONVERSION_RATE);
                }
            } else {
                _token.safeTransfer(distribution.receivers[i], _amount);
            }
            emit Distributed(distribution.receivers[i], distribution.percentages[i], _amount);
        }
    }

    function internalSetDistribution(address[] memory _receivers, uint256[] memory _percentages) internal {
        require(_receivers.length == _percentages.length, "Invalid distribution configuration");
        uint256 _totalPercentages = 0;
        for (uint256 i = 0; i < _percentages.length; i++) {
            _totalPercentages = _totalPercentages.add(_percentages[i]);
        }
        require(_totalPercentages == 10000, "Invalid distribution percentages");
        distribution.receivers = _receivers;
        distribution.percentages = _percentages;
        emit DistributionUpdated(_receivers, _percentages);
    }

    function getDistribution() public view returns (address[] memory, uint256[] memory) {
        return (distribution.receivers, distribution.percentages);
    }

    function getRevision() internal pure returns (uint256) {
        return IMPLEMENTATION_REVISION;
    }
}
