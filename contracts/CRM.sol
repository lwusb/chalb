// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// 固定OpenZeppelin版本为4.9.6（Remix会自动拉取）
import "@openzeppelin/contracts@4.9.6/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.6/token/ERC20/utils/SafeERC20.sol";

// PancakeSwap V2 核心接口（获取交易对+价格）
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title CRM
 * @dev 修复编译错误版：适配OpenZeppelin 4.9.6 + 修复核心逻辑错误
 * 功能：买入开关+1U价格限制+白名单特权+精准手续费监听
 */
contract CRM is ERC20, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    // ========== 核心状态变量 ==========
    address public routerAddress;
    address public pairAddress;
    address public usdtAddress;       
    address public gudiAddress1;      
    address public gudiAddress2;      
    uint256 public buyPercent;        
    uint256 public sellPercent;       

    bool public buyEnabled;           
    mapping(address => bool) public whitelist; 

    // ========== 事件定义 ==========
    event BuyFeeDeducted(address indexed from, address indexed to, uint256 indexed feeAmount, uint256 totalAmount);
    event SellFeeDeducted(address indexed from, address indexed to, uint256 indexed feeAmount, uint256 totalAmount);
    event ConfigUpdated(address indexed gudi1, address indexed gudi2, uint256 buyFee, uint256 sellFee);
    event BuyEnabledUpdated(bool indexed enabled);
    event WhitelistAdded(address indexed user);
    event WhitelistRemoved(address indexed user);

    // ========== 构造函数（修复所有编译错误） ==========
    constructor() ERC20("Core RDA Matrix", "CRM") {
        // 1. 初始发行量：1000亿枚（18位小数）
        uint256 initialSupply = 10000000000 * 10 ** decimals();
        _mint(_msgSender(), initialSupply);

        // 2. 部署者授予最高管理员权限（适配低版本OpenZeppelin，无返回值）
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // 3. 链ID适配：BSC测试网(97) / 主网(56)
        if (block.chainid == 97) {
            routerAddress = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;  // 测试网PancakeSwap路由
            usdtAddress = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;    // 测试网USDT
        } else {
            routerAddress = 0x10ED43C718714eb63d5aA57B78B54704E256024E;  // 主网PancakeSwap路由
            usdtAddress = 0x55d398326f99059fF775485246999027B3197955;    // 主网USDT
        }

        // 4. 手续费接收地址初始配置
        gudiAddress1 = 0x5E43159eF999537080E66EBffA09672484162906;
        gudiAddress2 = 0x28f7056ab66024f5B719175b2314F48c8B35D694;

        // 5. 手续费比例初始配置（3%）
        buyPercent = 300;
        sellPercent = 300;

        // 6. 新增功能初始化：上线默认禁止买入
        buyEnabled = false;
        pairAddress = address(0);
    }

    // ========== 核心转账逻辑（修复safeTransferFrom错误） ==========
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (pairAddress == address(0)) {
            pairAddress = IUniswapV2Factory(IUniswapV2Router02(routerAddress).factory()).getPair(address(this), usdtAddress);
        }

        require(from != address(0), "CRM: transfer from zero address");
        require(to != address(0), "CRM: transfer to zero address");
        require(amount > 0, "CRM: transfer amount too small");

        if (from == pairAddress) {
            _handleBuy(from, to, amount);
        } else if (to == pairAddress) {
            _handleSell(from, to, amount);
        } else {
            super._transfer(from, to, amount);
        }
    }

    // ========== 买入交易处理（修复手续费转账逻辑） ==========
    function _handleBuy(address from, address to, uint256 amount) internal {
        if (whitelist[to]) {
            super._transfer(from, to, amount);
            return;
        }

        require(buyEnabled, "CRM: buy is disabled now");
        uint256 crmPrice = getCrmPriceInUsdt();
        require(crmPrice >= 1 * 10 ** 18, "CRM: price < 1U, buy forbidden");

        uint256 fee = amount * buyPercent / 10000;
        uint256 transferAmount = amount - fee;

        // 修复：内部转账用_safeTransfer（替代错误的safeTransferFrom）
        if (fee > 0) {
            super._transfer(from, gudiAddress1, fee);
            emit BuyFeeDeducted(from, to, fee, amount);
        }
        super._transfer(from, to, transferAmount);
    }

    // ========== 卖出交易处理（修复手续费转账逻辑） ==========
    function _handleSell(address from, address to, uint256 amount) internal {
        if (whitelist[from]) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 fee = amount * sellPercent / 10000;
        uint256 transferAmount = amount - fee;

        if (fee > 0) {
            super._transfer(from, gudiAddress2, fee);
            emit SellFeeDeducted(from, to, fee, amount);
        }
        super._transfer(from, to, transferAmount);
    }

    // ========== 核心工具函数：获取CRM的USDT价格 ==========
    function getCrmPriceInUsdt() public view returns (uint256) {
        address crmUsdtPair = IUniswapV2Factory(IUniswapV2Router02(routerAddress).factory()).getPair(address(this), usdtAddress);
        require(crmUsdtPair != address(0), "CRM: CRM-USDT pair not exist");

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(crmUsdtPair).getReserves();
        address token0 = IUniswapV2Pair(crmUsdtPair).token0();

        (uint256 crmReserve, uint256 usdtReserve) = token0 == address(this) ? (reserve0, reserve1) : (reserve1, reserve0);
        require(crmReserve > 0 && usdtReserve > 0, "CRM: insufficient liquidity");

        return (usdtReserve * 10 ** 18) / crmReserve;
    }

    // ========== 管理员核心功能（复用AccessControl内置的DEFAULT_ADMIN_ROLE） ==========
    function setBuyEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        buyEnabled = _enabled;
        emit BuyEnabledUpdated(_enabled);
    }

    function addWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_user != address(0), "CRM: user can't be zero");
        whitelist[_user] = true;
        emit WhitelistAdded(_user);
    }

    function batchAddWhitelist(address[] calldata _users) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            if (user != address(0)) {
                whitelist[user] = true;
                emit WhitelistAdded(user);
            }
        }
    }

    function removeWhitelist(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[_user] = false;
        emit WhitelistRemoved(_user);
    }

    function setConfig(address _gudi1, address _gudi2, uint256 _buyPct, uint256 _sellPct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_gudi1 != address(0) && _gudi2 != address(0), "CRM: fee address can't be zero");
        require(_buyPct <= 500 && _sellPct <= 500, "CRM: max fee is 5%");
        require(_buyPct >= 0 && _sellPct >= 0, "CRM: fee can't be negative");

        gudiAddress1 = _gudi1;
        gudiAddress2 = _gudi2;
        buyPercent = _buyPct;
        sellPercent = _sellPct;
        emit ConfigUpdated(_gudi1, _gudi2, _buyPct, _sellPct);
    }

    function adminWithdraw(address _to, address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_to != address(0), "CRM: to can't be zero");
        require(_amount > 0, "CRM: amount must > 0");

        if (_token == address(0)) {
            require(address(this).balance >= _amount, "CRM: insufficient BNB");
            (bool success, ) = payable(_to).call{value: _amount}("");
            require(success, "CRM: BNB transfer failed");
        } else {
            require(IERC20(_token).balanceOf(address(this)) >= _amount, "CRM: insufficient token");
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    // ========== 接收BNB函数 ==========
    receive() external payable {}
}