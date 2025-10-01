// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        return c;
    }
}

/**
 * PRC20 standard interface.
 */
interface IPRC20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

abstract contract Auth {
    address internal owner;
    mapping (address => bool) internal authorizations;

    constructor(address _owner) {
        owner = _owner;
        authorizations[_owner] = true;
    }

    modifier onlyOwner() {
        require(isOwner(msg.sender), "!OWNER"); _;
    }

    modifier authorized() {
        require(isAuthorized(msg.sender), "!AUTHORIZED"); _;
    }

    function isOwner(address account) public view returns (bool) {
        return account == owner;
    }

    function isAuthorized(address adr) public view returns (bool) {
        return authorizations[adr];
    }

    function transferOwnership(address payable adr) public onlyOwner {
        owner = adr;
        authorizations[adr] = true;
        emit OwnershipTransferred(adr);
    }

    event OwnershipTransferred(address owner);
}

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}





contract PlenusMoon is IPRC20, Auth {
    using SafeMath for uint256;

    address WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address DEAD = 0x0000000000000000000000000000000000000369;
    address ZERO = 0x0000000000000000000000000000000000000369;

    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping (address => bool) isFeeExempt;

    bool public notliftoff = true;

    uint256 public liquidityFee           = 10; // 1% Add Token/PLS LP
    uint256 public launchFundFee          = 10; // 1% Next token Launch Funding
    uint256 public buyburnFee             = 10; // 1% Buy and Burn of SURF
    uint256 public charityFee             = 5; // 0.5% Charity
    uint256 public burnFee                = 5; // 0.5% Burn Token
    uint256 public faithfulHoldersFee     = 10; // 1% Faithful Holders
    uint256 public totalFee               = liquidityFee + launchFundFee + charityFee + buyburnFee + burnFee + faithfulHoldersFee;
    uint256 public feeDenominator         = 1000;

    uint256 public sellMultiplier  = 100;

    address public autoLiquidityReceiver;
    address public launchFundFeeReceiver;
    address public charityFeeReceiver;
    address public faithfulHoldersFeeReceiver;

    uint256 targetLiquidity = 100;
    uint256 targetLiquidityDenominator = 100;

    IDEXRouter public router;
    address public pair;

    bool public tradingOpen = false;

    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply * 10 / 10000; // 0.1% of supply
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    event AutoLiquify(uint256 amountPLS, uint256 amountBOG);

    constructor (
        string memory tokenName, 
        string memory tokenSymbol, 
        uint8 tokenDecimals, 
        uint256 tokenTotalSupply,
        address adminWallet
    ) Auth(adminWallet) {
        _name = tokenName;
        _symbol = tokenSymbol;
        _decimals = tokenDecimals; 
        _totalSupply = tokenTotalSupply.mul(10**uint256(tokenDecimals));
        swapThreshold = _totalSupply * 10 / 10000;

        router = IDEXRouter(0x165C3410fC91EF562C50559f7d2289fEbed552d9);
        pair = IDEXFactory(router.factory()).createPair(WPLS, address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;

        isFeeExempt[adminWallet] = true;
        autoLiquidityReceiver = adminWallet;
        launchFundFeeReceiver = adminWallet;
        charityFeeReceiver = adminWallet;
        faithfulHoldersFeeReceiver = adminWallet;

        _balances[adminWallet] = _totalSupply;
        emit Transfer(address(0), adminWallet, _totalSupply);
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external view override returns (uint8) { return _decimals; }
    function symbol() external view override returns (string memory) { return _symbol; }
    function name() external view override returns (string memory) { return _name; }
    function getOwner() external view override returns (address) { return owner; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }


    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        if(inSwap){ return _basicTransfer(sender, recipient, amount); }

        if(!authorizations[sender] && !authorizations[recipient]){
            require(tradingOpen,"Trading not open yet");
        }

        if(shouldSwapBack()){ swapBack(); }

        //Exchange tokens
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, amount,(recipient == pair)) : amount;
        _balances[recipient] = _balances[recipient].add(amountReceived);

        emit Transfer(sender, recipient, amountReceived);
        return true;
    }
    
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function shouldTakeFee(address sender, address recipient) internal view returns (bool) {
        if (isFeeExempt[recipient]){
            return false;
        }
        return !isFeeExempt[sender];
    }

    function buyburn(uint256 amount) internal {
        IPRC20 surf = IPRC20(0x12828D4cdA7CBfAcd7586E54708A9b9674641bEd); //SURF

        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(surf);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 surfAmount = surf.balanceOf(address(this));
        surf.transfer(DEAD, surfAmount);
    }

    function takeFee(address sender, uint256 amount, bool isSell) internal returns (uint256) {
        
        uint256 multiplier = isSell ? sellMultiplier : 100;
        uint256 feeAmount = amount.mul(totalFee).mul(multiplier).div(feeDenominator * 100);
        uint256 burnAmount = amount.mul(burnFee).div(feeDenominator);

        if (burnAmount > 0){
            _balances[DEAD] = _balances[DEAD].add(burnAmount);
            emit Transfer(sender, DEAD, burnAmount);
        }

        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);

        return amount.sub(feeAmount).sub(burnAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }

    function clearStuckBalance_sender(uint256 amountPercentage) external authorized {
        uint256 amountPLS = address(this).balance;
        payable(msg.sender).transfer(amountPLS * amountPercentage / 100);
    }

    function set_sell_multiplier(uint256 Multiplier) external onlyOwner{
        sellMultiplier = Multiplier;        
    }

    function addPLSLp(uint256 amountToLiquify, uint256 amountPLSLiquidity) internal {
        if(amountToLiquify > 0){
            router.addLiquidityETH{value: amountPLSLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountPLSLiquidity, amountToLiquify);
        }
    }

    function swapBack() internal swapping {
        uint256 dynamicLiquidityFee = isOverLiquified(targetLiquidity, targetLiquidityDenominator) ? 0 : liquidityFee;
        uint256 amountToLiquify = swapThreshold.mul(dynamicLiquidityFee).div(totalFee).div(2);
        uint256 amountToSwap = swapThreshold.sub(amountToLiquify);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WPLS;

        uint256 balanceBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountPLS = address(this).balance.sub(balanceBefore);

        uint256 totalPLSFee = totalFee.sub(dynamicLiquidityFee.div(2));

        uint256 amountPLSLiquidity = amountPLS.mul(dynamicLiquidityFee).div(totalPLSFee).div(2);
        uint256 amountPLSLaunchFund = amountPLS.mul(launchFundFee).div(totalPLSFee);
        uint256 amountPLSBuyburn = amountPLS.mul(buyburnFee).div(totalPLSFee);
        uint256 amountPLSCharity = amountPLS.mul(charityFee).div(totalPLSFee);
        uint256 amountPLSFaithfulHolders = amountPLS.mul(faithfulHoldersFee).div(totalPLSFee);

        if (amountPLSBuyburn > 0) {
            buyburn(amountPLSBuyburn);
        }

        (bool tmpSuccess,) = payable(charityFeeReceiver).call{value: amountPLSCharity, gas: 30000}("");

        // Supress warning msg
        tmpSuccess = false;

        (bool tmpSuccess3,) = payable(faithfulHoldersFeeReceiver).call{value: amountPLSFaithfulHolders, gas: 30000}("");
        // Supress warning msg
        tmpSuccess3 = false;

        addPLSLp(amountToLiquify,amountPLSLiquidity);

        uint256 remainder = address(this).balance - amountPLSLaunchFund - amountPLSFaithfulHolders;

        (bool tmpSuccess2,) = payable(launchFundFeeReceiver).call{value: amountPLSLaunchFund+remainder, gas: 30000}("");
        // Supress warning msg
        tmpSuccess2 = false;
    }

    function setIsFeeExempt(address holder, bool exempt) external authorized {
        isFeeExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _launchFundFee, uint256 _charityFee, uint256 _burnFee, uint256 _buyburnFee, uint256 _faithfulHoldersFee) external authorized {
        liquidityFee = _liquidityFee;
        launchFundFee = _launchFundFee;
        charityFee = _charityFee;
        burnFee = _burnFee;
        buyburnFee = _buyburnFee;
        faithfulHoldersFee = _faithfulHoldersFee;
        totalFee = _liquidityFee + _launchFundFee + _charityFee + _burnFee + _buyburnFee + _faithfulHoldersFee;
        feeDenominator = 1000;
        require(totalFee < 55, "Fees cannot be more than 5%");
    }

    function liftoff() public onlyOwner {
        require(notliftoff, "Moon mission already a go");
        tradingOpen = true;

        notliftoff = false;
    }

    function setFeeReceivers(address _autoLiquidityReceiver, address _launchFundFeeReceiver, address _charityFeeReceiver, address _faithfulHoldersFeeReceiver ) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        launchFundFeeReceiver = _launchFundFeeReceiver;
        charityFeeReceiver = _charityFeeReceiver;
        faithfulHoldersFeeReceiver = _faithfulHoldersFeeReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external authorized {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external authorized {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }
    
    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        return accuracy.mul(balanceOf(pair).mul(2)).div(getCirculatingSupply());
    }

    function isOverLiquified(uint256 target, uint256 accuracy) public view returns (bool) {
        return getLiquidityBacking(accuracy) > target;
    }

}