pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-solidity/contracts/utils/Address.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "../libraries/openzeppelin-upgradeability/VersionedInitializable.sol";

import "../configuration/LendingPoolAddressesProvider.sol";
import "../configuration/LendingPoolParametersProvider.sol";
import "../configuration/SingularityConfig.sol";
import "../tokenization/AToken.sol";
import "../libraries/CoreLibrary.sol";
import "../libraries/WadRayMath.sol";
import "../interfaces/IFeeProvider.sol";
import "../flashloan/interfaces/IFlashLoanReceiver.sol";
import "./LendingPoolCore.sol";
import "./LendingPoolDataProvider.sol";
import "./LendingPoolLiquidationManager.sol";
import "../libraries/EthAddressLib.sol";

/**
* @title LendingPool contract
* @notice Implements the actions of the LendingPool, and exposes accessory methods to fetch the users and reserve data
* @author VersoriumX Technology
 **/

contract LendingPool is ReentrancyGuard, VersionedInitializable {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using Address for address;

    LendingPoolAddressesProvider public addressesProvider;
    LendingPoolCore public core;
    LendingPoolDataProvider public dataProvider;
    LendingPoolParametersProvider public parametersProvider;
    SingularityConfig public singularityConfig;
    IFeeProvider feeProvider;

    event Deposit(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint16 indexed _referral,
        uint256 _timestamp
    );

    event RedeemUnderlying(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _timestamp
    );

    event Borrow(
        address indexed _reserve,
        address indexed _user,
        uint256 _amount,
        uint256 _borrowRateMode,
        uint256 _borrowRate,
        uint256 _originationFee,
        uint256 _borrowBalanceIncrease,
        uint16 indexed _referral,
        uint256 _timestamp
    );

    event Repay(
        address indexed _reserve,
        address indexed _user,
        address indexed _repayer,
        uint256 _amountMinusFees,
        uint256 _fees,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    event LiquidationCall(
        address indexed _collateral,
        address indexed _reserve,
        address indexed _user,
        uint256 _purchaseAmount,
        uint256 _liquidatedCollateralAmount,
        uint256 _accruedBorrowInterest,
        address _liquidator,
        bool _receiveAToken,
        uint256 _timestamp
    );

    event FlashLoan(
        address indexed _target,
        address indexed _reserve,
        uint256 _amount,
        uint256 _totalFee,
        uint256 _protocolFee,
        uint256 _timestamp
    );

    event ReserveUpdated(
        address indexed _reserve,
        uint256 _liquidityRate,
        uint256 _stableBorrowRate,
        uint256 _variableBorrowRate,
        uint256 _liquidityIndex,
        uint256 _variableBorrowIndex,
        uint256 _timestamp
    );

    event Swap(
        address indexed _reserve,
        address indexed _user,
        uint256 _newRateMode,
        uint256 _newRate,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    event ReserveUsedAsCollateralEnabled(address indexed _reserve, address indexed _user);
    event ReserveUsedAsCollateralDisabled(address indexed _reserve, address indexed _user);

    event RebalanceStableBorrowRate(
        address indexed _reserve,
        address indexed _user,
        uint256 _newStableRate,
        uint256 _borrowBalanceIncrease,
        uint256 _timestamp
    );

    modifier onlyActiveReserve(address _reserve) {
        require(core.getReserveIsActive(_reserve), "Action requires an active reserve");
        _;
    }

    modifier onlyUnfreezedReserve(address _reserve) {
        require(!core.getReserveIsFreezed(_reserve), "Action requires an unfreezed reserve");
        _;
    }

    modifier onlyAmountGreaterThanZero(uint256 _amount) {
        require(_amount > 0, "Amount must be greater than 0");
        _;
    }

    uint256 public constant LENDINGPOOL_REVISION = 0x2;

    function getRevision() internal pure returns (uint256) {
        return LENDINGPOOL_REVISION;
    }

    function initialize(LendingPoolAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
        core = LendingPoolCore(addressesProvider.getLendingPoolCore());
        dataProvider = LendingPoolDataProvider(addressesProvider.getLendingPoolDataProvider());
        parametersProvider = LendingPoolParametersProvider(
            addressesProvider.getLendingPoolParametersProvider()
        );
        singularityConfig = SingularityConfig(addressesProvider.getSingularityConfig());
        feeProvider = IFeeProvider(addressesProvider.getFeeProvider());
    }

    function deposit(address _reserve, uint256 _amount, uint16 _referralCode)
        external
        payable
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        AToken aToken = AToken(core.getReserveATokenAddress(_reserve));
        bool isFirstDeposit = aToken.balanceOf(msg.sender) == 0;
        core.updateStateOnDeposit(_reserve, msg.sender, _amount, isFirstDeposit);
        aToken.mintOnDeposit(msg.sender, _amount);
        core.transferToReserve.value(msg.value)(_reserve, msg.sender, _amount);
        emit Deposit(_reserve, msg.sender, _amount, _referralCode, block.timestamp);
    }

    function redeemUnderlying(
        address _reserve,
        address payable _user,
        uint256 _amount,
        uint256 _aTokenBalanceAfterRedeem
    ) external nonReentrant onlyActiveReserve(_reserve) {
        require(_amount > 0, "Amount must be greater than 0");
        uint256 availableLiquidityBefore = core.getReserveAvailableLiquidity(_reserve);
        require(
            availableLiquidityBefore >= _amount,
            "There is not enough liquidity available to redeem"
        );
        core.updateStateOnRedeem(_reserve, _user, _amount, _aTokenBalanceAfterRedeem == 0);
        core.transferToUser(_reserve, _user, _amount);
        emit RedeemUnderlying(_reserve, _user, _amount, block.timestamp);
    }

    function borrow(
        address _reserve,
        uint256 _amount,
        uint256 _interestRateMode,
        uint16 _referralCode
    )
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        require(dataProvider.balanceDecreaseAllowed(_reserve, msg.sender, _amount), "Borrow not allowed");
        require(
            core.getReserveAvailableLiquidity(_reserve) >= _amount,
            "There is not enough liquidity available to borrow"
        );
        (uint256 borrowRate, uint256 balanceIncrease) = core
            .updateStateOnBorrow(_reserve, msg.sender, _amount, 0, CoreLibrary.InterestRateMode(_interestRateMode));
        core.transferToUser(_reserve, msg.sender, _amount);
        emit Borrow(
            _reserve,
            msg.sender,
            _amount,
            _interestRateMode,
            borrowRate,
            0,
            balanceIncrease,
            _referralCode,
            block.timestamp
        );
    }

    function repay(address _reserve, uint256 _amount, address payable _user)
        external
        payable
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        (uint256 principal, uint256 compounded, uint256 increase) = core.getUserBorrowBalances(_reserve, _user);
        uint256 paybackAmount = _amount == uint256(-1) ? compounded : _amount;
        core.updateStateOnRepay(_reserve, _user, paybackAmount, 0, increase, paybackAmount == compounded);
        if (_reserve != EthAddressLib.ethAddress()) {
            core.transferToReserve(_reserve, msg.sender, paybackAmount);
        } else {
            if (msg.value > paybackAmount) {
                msg.sender.transfer(msg.value.sub(paybackAmount));
            }
        }
        emit Repay(_reserve, _user, msg.sender, paybackAmount, 0, increase, block.timestamp);
    }

    function swapBorrowRateMode(address _reserve)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
    {
        (uint256 principal, uint256 compounded, uint256 increase) = core.getUserBorrowBalances(_reserve, msg.sender);
        CoreLibrary.InterestRateMode currentMode = core.getUserCurrentBorrowRateMode(_reserve, msg.sender);
        (CoreLibrary.InterestRateMode newMode, uint256 newRate) = core.updateStateOnSwapRate(
            _reserve, msg.sender, principal, compounded, increase, currentMode
        );
        emit Swap(_reserve, msg.sender, uint256(newMode), newRate, increase, block.timestamp);
    }

    function rebalanceStableBorrowRate(address _reserve, address _user)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
    {
        (,, uint256 increase) = core.getUserBorrowBalances(_reserve, _user);
        uint256 newRate = core.updateStateOnRebalance(_reserve, _user, increase);
        emit RebalanceStableBorrowRate(_reserve, _user, newRate, increase, block.timestamp);
    }

    function setUserUseReserveAsCollateral(address _reserve, bool _useAsCollateral)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyUnfreezedReserve(_reserve)
    {
        if (_useAsCollateral) {
            (,,,,bool enabled,,,) = dataProvider.getReserveConfigurationData(_reserve);
            require(enabled, "Reserve cannot be used as collateral");
        } else {
            require(dataProvider.balanceDecreaseAllowed(_reserve, msg.sender, 0), "Action not allowed");
        }
        core.setUserUseReserveAsCollateral(_reserve, msg.sender, _useAsCollateral);
        if (_useAsCollateral) {
            emit ReserveUsedAsCollateralEnabled(_reserve, msg.sender);
        } else {
            emit ReserveUsedAsCollateralDisabled(_reserve, msg.sender);
        }
    }

    function liquidationCall(
        address _collateral,
        address _reserve,
        address _user,
        uint256 _purchaseAmount,
        bool _receiveAToken
    ) external payable nonReentrant onlyActiveReserve(_reserve) onlyActiveReserve(_collateral) {
        address manager = addressesProvider.getLendingPoolLiquidationManager();
        (bool success, bytes memory result) = manager.delegatecall(
            abi.encodeWithSignature("liquidationCall(address,address,address,uint256,bool)",
            _collateral, _reserve, _user, _purchaseAmount, _receiveAToken)
        );
        require(success, "Liquidation call failed");
        (uint256 code, string memory message) = abi.decode(result, (uint256, string));
        if (code != 0) {
            revert(string(abi.encodePacked("Liquidation failed: ", message)));
        }
    }

    struct FlashLoanLocalVars {
        uint256 availableBefore;
        uint256 totalFeeBips;
        uint256 protocolFeeBips;
        uint256 amountFee;
        uint256 protocolFee;
        uint256 availableAfter;
    }

    function flashLoan(address _receiver, address _reserve, uint256 _amount, bytes calldata _params)
        external
        nonReentrant
        onlyActiveReserve(_reserve)
        onlyAmountGreaterThanZero(_amount)
    {
        FlashLoanLocalVars memory vars;
        vars.availableBefore = _reserve == EthAddressLib.ethAddress() ? address(core).balance : IERC20(_reserve).balanceOf(address(core));
        require(vars.availableBefore >= _amount, "Not enough liquidity");
        (vars.totalFeeBips, vars.protocolFeeBips) = parametersProvider.getFlashLoanFeesInBips();
        vars.amountFee = _amount.mul(vars.totalFeeBips).div(10000);
        vars.protocolFee = vars.amountFee.mul(vars.protocolFeeBips).div(10000);
        require(vars.amountFee > 0 && vars.protocolFee > 0, "Amount too small");

        core.transferToUser(_reserve, address(uint160(_receiver)), _amount);

        IFlashLoanReceiver(_receiver).executeOperation(_reserve, _amount, vars.amountFee, _params);

        vars.availableAfter = _reserve == EthAddressLib.ethAddress() ? address(core).balance : IERC20(_reserve).balanceOf(address(core));
        require(vars.availableAfter == vars.availableBefore.add(vars.amountFee), "Inconsistent balance");

        core.updateStateOnFlashLoan(_reserve, vars.availableBefore, vars.amountFee.sub(vars.protocolFee), vars.protocolFee);
        emit FlashLoan(_receiver, _reserve, _amount, vars.amountFee, vars.protocolFee, block.timestamp);
    }

    function getReserveConfigurationData(address _reserve) external view returns (uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus, address rateStrategyAddress, bool usageAsCollateralEnabled, bool borrowingEnabled, bool stableBorrowRateEnabled, bool isActive) {
        return dataProvider.getReserveConfigurationData(_reserve);
    }

    function getReserveData(address _reserve) external view returns (uint256 totalLiquidity, uint256 availableLiquidity, uint256 totalBorrowsStable, uint256 totalBorrowsVariable, uint256 liquidityRate, uint256 variableBorrowRate, uint256 stableBorrowRate, uint256 averageStableBorrowRate, uint256 utilizationRate, uint256 liquidityIndex, uint256 variableBorrowIndex, address aTokenAddress, uint40 lastUpdateTimestamp) {
        return dataProvider.getReserveData(_reserve);
    }

    function getUserAccountData(address _user) external view returns (uint256 totalLiquidityETH, uint256 totalCollateralETH, uint256 totalBorrowsETH, uint256 totalFeesETH, uint256 availableBorrowsETH, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor) {
        return dataProvider.getUserAccountData(_user);
    }

    function getUserReserveData(address _reserve, address _user) external view returns (uint256 currentATokenBalance, uint256 currentBorrowBalance, uint256 principalBorrowBalance, uint256 borrowRateMode, uint256 borrowRate, uint256 liquidityRate, uint256 originationFee, uint256 variableBorrowIndex, uint256 lastUpdateTimestamp, bool usageAsCollateralEnabled) {
        return dataProvider.getUserReserveData(_reserve, _user);
    }

    function getReserves() external view returns (address[] memory) {
        return core.getReserves();
    }

    function getSingularitySummary() external view returns (uint256 nodes, uint256 ratio, string memory version, string memory director) {
        nodes = singularityConfig.getTotalSingularityNodes();
        ratio = singularityConfig.getSymbioticReserveRatio();
        version = singularityConfig.PROTOCOL_VERSION();
        director = singularityConfig.DIRECTOR();
    }
}
