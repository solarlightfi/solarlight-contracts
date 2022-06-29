// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/IRewardPool.sol";

// SOLARLIGHT FINANCE
contract Treasury is ITreasury, ContractGuard, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private epoch_ = 0;
    uint256 private epochLength_ = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public flare;
    address public bflare;
    address public light;
    address public blight;

    address public override boardroom;
    address public flareOracle;
    address public lightOracle;

    // price
    uint256 public priceOne;
    uint256 public priceCeiling;

    mapping(address => uint256) public seigniorageSaved;

    mapping(address => uint256) public nextSupplyTarget;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 2% expansion regardless of flare price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    uint256 public override previousEpochPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra flare during debt phase

    address public override daoFund;
    uint256 public override daoFundSharedPercent; // 3000 (30%)

    address public override devFund;
    uint256 public override devFundSharedPercent; // 1000 (10%)

    address[] public supplyLockedAccounts;

    // Multi-Pegs
    address[] public pegTokens;
    mapping(address => address) public pegTokenOracle;
    mapping(address => address) public pegTokenFarmingPool; // to exclude balance from supply
    mapping(address => uint256) public pegTokenEpochStart;
    mapping(address => uint256) public pegTokenSupplyTarget;
    mapping(address => uint256) public pegTokenMaxSupplyExpansionPercent; // 1% = 10000
    bool public multiPegEnabled;
    mapping(uint256 => mapping(address => bool)) public hasAllocatedPegToken; // epoch => pegToken => true/false

    mapping(address => bool) public strategist;

    /* =================== Added variables =================== */
    mapping(address => bool) public pegTokenPriceUpdateDisabled;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address token, address bond, address indexed from, uint256 amount, uint256 bondAmount);
    event BoughtBonds(address token, address bond, address indexed from, uint256 amount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event FundingAdded(uint256 indexed epoch, uint256 timestamp, uint256 price, uint256 expanded, uint256 boardroomFunded, uint256 daoFunded, uint256 devFunded);
    event PegTokenFundingAdded(address indexed pegToken, uint256 indexed epoch, uint256 timestamp, uint256 price, uint256 expanded, uint256 boardroomFunded, uint256 daoFunded, uint256 devFunded);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "!operator");
        _;
    }

    modifier onlyStrategist() {
        require(strategist[msg.sender] || operator == msg.sender, "!strategist && !operator");
        _;
    }

    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(block.timestamp >= _nextEpochPoint, "!opened");

        _;

        lastEpochTime = _nextEpochPoint;
        epoch_ = epoch_.add(1);
        epochSupplyContractionLeft = (getFlarePrice() > priceCeiling) ? 0 : IERC20(flare).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(flare).operator() == address(this) &&
            IBasisAsset(bflare).operator() == address(this) &&
            IBasisAsset(light).operator() == address(this) &&
            IBasisAsset(blight).operator() == address(this),
            "need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // epoch
    function epoch() public override view returns (uint256) {
        return epoch_;
    }

    function nextEpochPoint() public override view returns (uint256) {
        return lastEpochTime.add(nextEpochLength());
    }

    function nextEpochLength() public override view returns (uint256) {
        return epochLength_;
    }

    // oracle
    function getFlarePrice() public override view returns (uint256 flarePrice) {
        try IOracle(flareOracle).consult(flare, 1e18) returns (uint144 price) {
            return uint256(price) * 1e12;
        } catch {
            revert("oracle failed");
        }
    }

    function getFlareUpdatedPrice() public override view returns (uint256 _flarePrice) {
        try IOracle(flareOracle).twap(flare, 1e18) returns (uint144 price) {
            return uint256(price) * 1e12;
        } catch {
            revert("oracle failed");
        }
    }

    function getLightPrice() public override view returns (uint256 lightPrice) {
        try IOracle(lightOracle).consult(light, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getLightUpdatedPrice() public override view returns (uint256 _lightPrice) {
        try IOracle(lightOracle).twap(light, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getPegTokenPrice(address _token) public override view returns (uint256 _pegTokenPrice) {
        if (_token == flare) {
            return getFlarePrice();
        }
        if (_token == light) {
            return getLightPrice();
        }
        try IOracle(pegTokenOracle[_token]).consult(_token, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function getPegTokenUpdatedPrice(address _token) public override view returns (uint256 _pegTokenPrice) {
        if (_token == flare) {
            return getFlareUpdatedPrice();
        }
        if (_token == light) {
            return getLightUpdatedPrice();
        }
        try IOracle(pegTokenOracle[_token]).twap(_token, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("oracle failed");
        }
    }

    function boardroomSharedPercent() external override view returns (uint256) {
        return uint256(10000).sub(daoFundSharedPercent).sub(devFundSharedPercent);
    }

    // budget
    function getReserve(address _token) external view returns (uint256) {
        return seigniorageSaved[_token];
    }

    function getBurnableLeft(address _token, address _bond) internal view returns (uint256 _burnableLeft) {
        uint256 _price = getPegTokenPrice(_token);
        if (_price <= priceOne) {
            uint256 _bondMaxSupply = IERC20(_token).totalSupply().mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(_bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableLight = _maxMintableBond.mul(getBondDiscountRate(_token)).div(1e18);
                _burnableLeft = Math.min(epochSupplyContractionLeft, _maxBurnableLight);
            }
        }
    }

    function getBurnableLightLeft() external view returns (uint256 _burnableLightLeft) {
        return getBurnableLeft(light, blight);
    }

    function getBurnableFlareLeft() external view returns (uint256 _burnableFlareLeft) {
        return getBurnableLeft(flare, bflare);
    }

    function getRedeemableBonds(address _token) external view returns (uint256 _redeemableBonds) {
        uint256 _price = getPegTokenPrice(_token);
        if (_price > priceCeiling) {
            uint256 _total = IERC20(_token).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate(_token);
            if (_rate > 0) {
                _redeemableBonds = _total.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate(address _token) public override view returns (uint256 _rate) {
        uint256 _price = getPegTokenPrice(_token);
        if (_price <= priceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = priceOne;
            } else {
                uint256 _bondAmount = priceOne.mul(1e18).div(_price); // to burn 1 flare
                uint256 _discountAmount = _bondAmount.sub(priceOne).mul(discountPercent).div(10000);
                _rate = priceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }


    function getBondPremiumRate(address _token) public override view returns (uint256 _rate) {
        uint256 _price = getPegTokenPrice(_token);
        if (_price > priceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = priceOne;
            } else {
                uint256 _premiumAmount = _price.sub(priceOne).mul(premiumPercent).div(10000);
                _rate = priceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getTokenCirculatingSupply(address _token) public  view returns (uint256) {
        return IERC20(_token).totalSupply().sub(getSupplyLockedBalance(_token));
    }

    function getSupplyLockedBalance(address token) public override view returns (uint256 _lockedBalance) {
        uint256 _length = supplyLockedAccounts.length;
        IERC20 _token = IERC20(token);
        for (uint256 i = 0; i < _length; i++) {
            _lockedBalance = _lockedBalance.add(_token.balanceOf(supplyLockedAccounts[i]));
        }
    }

    function getNextExpansionRate(address _token) public override view returns (uint256) {
        if (epoch_ < bootstrapEpochs) {// 28 first epochs with 4.5% expansion
            return bootstrapSupplyExpansionPercent * 100; // 1% = 1e16
        } else {
            return getPegTokenExpansionRate(_token);
        }
    }

    function getNextExpansionAmount(address _token) external override view returns (uint256) {
        return getTokenCirculatingSupply(_token).mul(getNextExpansionRate(_token)).div(1e6);
    }

    function pegTokenLength() external view returns (uint256) {
        return pegTokens.length;
    }

    function getCirculatingSupply(address _token) public view returns (uint256) {
        return IERC20(_token).totalSupply().sub(IERC20(_token).balanceOf(pegTokenFarmingPool[_token]));
    }

    function getPegTokenExpansionRate(address _pegToken) public override view returns (uint256 _rate) {
        if (_pegToken != flare && _pegToken != light) {
            uint256 _epochStart = pegTokenEpochStart[_pegToken];
            if (_epochStart == 0 || _epochStart > epoch_.add(1)) return 0;
        }
        uint256 _twap = getPegTokenUpdatedPrice(_pegToken);
        if (_twap > priceCeiling) {
            uint256 _percentage = _twap.sub(priceOne); // 1% = 1e16
            uint256 _mse = (_pegToken == flare || _pegToken == light) ? maxSupplyExpansionPercent.mul(1e14) : pegTokenMaxSupplyExpansionPercent[_pegToken].mul(1e12);
            if (_percentage > _mse) {
                _percentage = _mse;
            }
            _rate = _percentage.div(1e12);
        }
    }

    function getPegTokenExpansionAmount(address _pegToken) public override view returns (uint256) {
        uint256 _rate = getPegTokenExpansionRate(_pegToken);
        return getCirculatingSupply(_pegToken).mul(_rate).div(1e6);
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _flare,
        address _bflare,
        address _flareOracle,
        address _light,
        address _blight,
        address _lightOracle,
        address _boardroom,
        uint256 _startEpoch,
        uint256 _startTime
    ) public notInitialized {
        flare = _flare;
        bflare = _bflare;
        flareOracle = _flareOracle;
        light = _light;
        blight = _blight;
        lightOracle = _lightOracle;
        boardroom = _boardroom;

        epoch_ = _startEpoch;
        startTime = _startTime;
        epochLength_ = 1 hours;
        lastEpochTime = _startTime.sub(1 hours);

        priceOne = 10 ** 18; // This is to allow a PEG of 1 flare per VVS
        priceCeiling = priceOne.mul(1001).div(1000);

        maxSupplyExpansionPercent = 150; // Upto 1.5% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        maxSupplyContractionPercent = 750; // Upto 7.5% supply for contraction (to burn flare and mint bflare)
        maxDebtRatioPercent = 15000; // Upto 150% supply of bflare to purchase

        maxDiscountRate = 13e17; // 30% - when purchasing bond
        maxPremiumRate = 13e17; // 30% - when redeeming bond

        discountPercent = 0; // no discount
        premiumPercent = 6500; // 65% premium

        // First 28 epochs with 2% expansion
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 200;

        // set seigniorageSaved to it's balance
        seigniorageSaved[flare] = IERC20(flare).balanceOf(address(this));
        seigniorageSaved[light] = IERC20(light).balanceOf(address(this));

        nextSupplyTarget[flare] = 1000000 ether; // 1M supply
        nextSupplyTarget[light] = 8000000 ether; // 8M supply
        multiPegEnabled = true;

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setFlareOracle(address _flareOracle) external onlyOperator {
        flareOracle = _flareOracle;
    }

    function setLightOracle(address _lightOracle) external onlyOperator {
        lightOracle = _lightOracle;
    }

    function setPriceCeiling(uint256 _priceCeiling) external onlyOperator {
        require(_priceCeiling >= priceOne && _priceCeiling <= priceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        priceCeiling = _priceCeiling;
    }

    function setEpochLength(uint256 _epochLength) external onlyOperator {
        epochLength_ = _epochLength;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 40000, "out of range"); // [10%, 400%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function toggleMultiPegEnabled() external onlyOperator {
        multiPegEnabled = !multiPegEnabled;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFundSharedPercent == 0 || _daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 4000, "out of range"); // <= 40%
        require(_devFundSharedPercent == 0 || _devFund != address(0), "zero");
        require(_devFundSharedPercent <= 2000, "out of range"); // <= 20%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setDiscountConfig(uint256 _maxDiscountRate, uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "over 200%");
        maxDiscountRate = _maxDiscountRate;
        discountPercent = _discountPercent;
    }

    function setPremiumConfig(uint256 _maxPremiumRate, uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "over 200%");
        maxPremiumRate = _maxPremiumRate;
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function setNextSupplyTarget(address _token, uint256 _target) external onlyOperator {
        require(_target > IERC20(_token).totalSupply(), "too small");
        nextSupplyTarget[_token] = _target;
    }

    function setSupplyLockedAccounts(address[] memory _supplyLockedAccounts) external onlyOperator {
        delete supplyLockedAccounts;
        uint256 _length = _supplyLockedAccounts.length;
        for (uint256 i = 0; i < _length; i++) {
            supplyLockedAccounts.push(_supplyLockedAccounts[i]);
        }
    }

    function addPegToken(address _token) external onlyOperator {
        require(IERC20(_token).totalSupply() > 0, "invalid token");
        pegTokens.push(_token);
    }

    function setPegTokenConfig(address _token, address _oracle, address _pool, uint256 _epochStart, uint256 _supplyTarget, uint256 _expansionPercent) external onlyOperator {
        pegTokenOracle[_token] = _oracle;
        pegTokenFarmingPool[_token] = _pool;
        pegTokenEpochStart[_token] = _epochStart;
        pegTokenSupplyTarget[_token] = _supplyTarget;
        pegTokenMaxSupplyExpansionPercent[_token] = _expansionPercent;
    }

    function togglePegTokenPriceUpdateDisabled(address _token) external onlyOperator {
        pegTokenPriceUpdateDisabled[_token] = !pegTokenPriceUpdateDisabled[_token];
    }

    function setStrategistStatus(address _account, bool _status) external onlyOperator {
        strategist[_account] = _status;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function updatePrice(address _token) internal {
        if (_token == flare) {
            try IOracle(flareOracle).update() {} catch {}
        } else if (_token == light) {
            try IOracle(lightOracle).update() {} catch {}
        }
    }

    function _updatePegTokenPrice(address _token) internal {
        if (!pegTokenPriceUpdateDisabled[_token]) {
            try IOracle(pegTokenOracle[_token]).update() {} catch {}
        }
    }

    function buyBonds(address _token, address _bond, uint256 _amount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_amount > 0, "zero amount");

        uint256 price = getPegTokenPrice(_token);
        require(price == targetPrice, "price moved");
        require(
            price < priceOne, // price < $1
            "price is not eligible for bond purchase"
        );

        require(_amount <= epochSupplyContractionLeft, "not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate(_token);
        require(_rate > 0, "invalid bond rate");

        uint256 _bondAmount = _amount.mul(_rate).div(1e18);
        uint256 _tokenSupply = IERC20(_token).totalSupply();
        uint256 newBondSupply = IERC20(_bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= _tokenSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(_token).burnFrom(msg.sender, _amount);
        IBasisAsset(_bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_amount);
        updatePrice(_token);

        emit BoughtBonds(msg.sender, _token, _bond, _amount, _bondAmount);
    }

    function redeemBonds(address _token, address _bond, uint256 _bondAmount, uint256 targetPrice) external override onlyOneBlock checkOperator nonReentrant {
        require(_bondAmount > 0, "cannot redeem bonds with zero amount");

        uint256 price = getPegTokenPrice(_token);
        require(price == targetPrice, "price moved");
        require(
            price > priceCeiling, // price > $1.01
            "price is not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate(_token);
        require(_rate > 0, "invalid bond rate");

        uint256 _amount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "treasury has no more budget");

        seigniorageSaved[_token] = seigniorageSaved[_token].sub(Math.min(seigniorageSaved[_token], _amount));

        IBasisAsset(_bond).burnFrom(msg.sender, _bondAmount);
        IERC20(_token).safeTransfer(msg.sender, _amount);

        updatePrice(_token);

        emit RedeemedBonds(msg.sender, _token, _bond, _amount, _bondAmount);
    }

    function _sendToBoardroom(address _token, uint256 _amount, uint256 _expanded) internal {
        IBasisAsset(_token).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(_token).transfer(daoFund, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(_token).transfer(devFund, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(_token).safeIncreaseAllowance(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_token, _amount);

        emit FundingAdded(epoch_.add(1), block.timestamp, previousEpochPrice, _expanded,
            _amount, _daoFundSharedAmount, _devFundSharedAmount);
    }

    function _allocateSeigniorage(address _token, address _bond) internal {
        updatePrice(_token);
        previousEpochPrice = getPegTokenPrice(_token);
        uint256 _supply = getTokenCirculatingSupply(_token);
        uint256 _nextSupplyTarget = nextSupplyTarget[_token];
        if (_supply >= _nextSupplyTarget) {
            nextSupplyTarget[_token] = _nextSupplyTarget.mul(12000).div(10000); // +20%
            maxSupplyExpansionPercent = maxSupplyExpansionPercent.mul(9500).div(10000); // -5%
            if (maxSupplyExpansionPercent < 25) {
                maxSupplyExpansionPercent = 25; // min 0.25%
            }
        }
        uint256 _seigniorage;
        if (epoch_ < bootstrapEpochs) {
            // 28 first epochs with 2% expansion
            if (epoch_ == 0) _supply = IERC20(_token).totalSupply();
            _seigniorage = _supply.mul(bootstrapSupplyExpansionPercent).div(10000);
            _sendToBoardroom(_token, _seigniorage, _seigniorage);
        } else {
            if (previousEpochPrice > priceCeiling) {
                uint256 bondSupply = IERC20(_bond).totalSupply();
                uint256 _percentage = previousEpochPrice.sub(priceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved[_token] >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = _seigniorage = _supply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    _seigniorage = _supply.mul(_percentage).div(1e18);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_token, _savedForBoardroom, _seigniorage);
                } else {
                    emit FundingAdded(epoch_.add(1), block.timestamp, previousEpochPrice, 0, 0, 0, 0);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved[_token] = seigniorageSaved[_token].add(_savedForBond);
                    IBasisAsset(_token).mint(address(this), _savedForBond);
                    emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            } else if (previousEpochPrice < priceOne) {
                emit FundingAdded(epoch_.add(1), block.timestamp, previousEpochPrice, 0, 0, 0, 0);
            }
        }

    }

    function allocateSeigniorage() external onlyOneBlock checkEpoch checkOperator nonReentrant {
        _allocateSeigniorage(flare, bflare);
        _allocateSeigniorage(light, blight);
        if (multiPegEnabled) {
            uint256 _ptlength = pegTokens.length;
            for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
                address _pegToken = pegTokens[_pti];
                uint256 _epochStart = pegTokenEpochStart[_pegToken];
                if (_epochStart > 0 && _epochStart <= epoch_.add(1)) {
                    _updatePegTokenPrice(_pegToken);
                    _allocateSeignioragePegToken(epoch_, _pegToken);
                }
            }
        }
    }

    function _allocateSeignioragePegToken(uint256 _epoch, address _pegToken) internal {
        if (hasAllocatedPegToken[_epoch.add(1)][_pegToken]) return; // skip
        hasAllocatedPegToken[_epoch.add(1)][_pegToken] = true;
        uint256 _supply = getCirculatingSupply(_pegToken);
        if (_supply >= pegTokenSupplyTarget[_pegToken]) {
            pegTokenSupplyTarget[_pegToken] = pegTokenSupplyTarget[_pegToken].mul(12500).div(10000); // +25%
            pegTokenMaxSupplyExpansionPercent[_pegToken] = pegTokenMaxSupplyExpansionPercent[_pegToken].mul(9500).div(10000); // -5%
            if (pegTokenMaxSupplyExpansionPercent[_pegToken] < 1000) {
                pegTokenMaxSupplyExpansionPercent[_pegToken] = 1000; // min 0.1%
            }
        }
        uint256 _pegTokenTwap = getPegTokenPrice(_pegToken);
        if (_pegTokenTwap > priceCeiling) {
            uint256 _percentage = _pegTokenTwap.sub(priceOne); // 1% = 1e16
            uint256 _mse = pegTokenMaxSupplyExpansionPercent[_pegToken].mul(1e12); // 10000 = 1%
            if (_percentage > _mse) {
                _percentage = _mse;
            }
            uint256 _expanded = _supply.mul(_percentage).div(1e18);
            uint256 _daoFundSharedAmount = 0;
            uint256 _devFundSharedAmount = 0;
            uint256 _boardroomAmount = 0;
            if (_expanded > 0) {
                IBasisAsset(_pegToken).mint(address(this), _expanded);

                if (daoFundSharedPercent > 0) {
                    _daoFundSharedAmount = _expanded.mul(daoFundSharedPercent).div(10000);
                    IERC20(_pegToken).transfer(daoFund, _daoFundSharedAmount);
                }

                if (devFundSharedPercent > 0) {
                    _devFundSharedAmount = _expanded.mul(devFundSharedPercent).div(10000);
                    IERC20(_pegToken).transfer(devFund, _devFundSharedAmount);
                }
                _boardroomAmount = _expanded.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

                IERC20(_pegToken).safeIncreaseAllowance(boardroom, _boardroomAmount);
                IBoardroom(boardroom).allocateSeigniorage(_pegToken, _boardroomAmount);
            }

            emit PegTokenFundingAdded(_pegToken, _epoch.add(1), block.timestamp, _pegTokenTwap, _expanded,
                _boardroomAmount, _daoFundSharedAmount, _devFundSharedAmount);
        }
    }

    /**
     * @dev should call this after the main function allocateSeigniorage()
     */
    function governanceAllocateSeignioragePegToken(address _pegToken) public onlyStrategist {
        _updatePegTokenPrice(_pegToken);
        uint256 _epoch = (epoch_ == 0) ? 0 : epoch_.sub(1);
        _allocateSeignioragePegToken(_epoch, _pegToken);
    }

    function governanceAllocateSeigniorageForAllPegTokens() external {
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _pegToken = pegTokens[_pti];
            uint256 _epochStart = pegTokenEpochStart[_pegToken];
            if (_epochStart > 0 && _epochStart <= epoch_) {
                governanceAllocateSeignioragePegToken(_pegToken);
            }
        }
    }

    function governanceUpdatePricePegToken(address _pegToken) public onlyStrategist {
        IOracle(_pegToken).update();
    }

    function governanceUpdatePriceForAllPegTokens() external onlyStrategist {
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            governanceUpdatePricePegToken(pegTokens[_pti]);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(flare), "flare");
        require(address(_token) != address(bflare), "bflare");
        _token.safeTransfer(_to, _amount);
    }

    function tokenTransferOperator(address _token, address _operator) external onlyOperator {
        IBasisAsset(_token).transferOperator(_operator);
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomGovernanceRecoverUnsupported(address _boardRoomOrToken, address _token, uint256 _amount, address _to) external onlyOperator {
        IBoardroom(_boardRoomOrToken).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
