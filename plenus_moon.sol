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

interface IDividendDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external payable;
    function process(uint256 gas) external;
}

contract DividendDistributor is IDividendDistributor {
    using SafeMath for uint256;

    address _token;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IPRC20 RWRD = IPRC20(0x95B303987A60C71504D99Aa1b13B4DA07b0790ab); // PLSX Reward Address
    address WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    IDEXRouter router;

    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;

    mapping (address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;

    uint256 public minPeriod = 0;
    uint256 public minDistribution = 0;

    uint256 currentIndex;

    bool initialized;
    modifier initialization() {
        require(!initialized);
        _;
        initialized = true;
    }

    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _router) {
        router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x165C3410fC91EF562C50559f7d2289fEbed552d9);
        _token = msg.sender;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }

    function deposit() external payable override onlyToken {
        uint256 balanceBefore = RWRD.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(RWRD);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amount = RWRD.balanceOf(address(this)).sub(balanceBefore);

        totalDividends = totalDividends.add(amount);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }

            if(shouldDistribute(shareholders[currentIndex])){
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
                && getUnpaidEarnings(shareholder) > minDistribution;
    }

    function distributeDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidEarnings(shareholder);
        if(amount > 0){
            totalDistributed = totalDistributed.add(amount);
            RWRD.transfer(shareholder, amount);
            shareholderClaims[shareholder] = block.timestamp;
            shares[shareholder].totalRealised = shares[shareholder].totalRealised.add(amount);
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
        }
    }
    
    function claimDividend() external {
        distributeDividend(msg.sender);
    }

    function getUnpaidEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }

    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal {
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder];
        shareholders.pop();
    }
}

contract YakDao is IPRC20, Auth {
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
    mapping (address => bool) isDividendExempt;

    bool public notliftoff = true;

    uint256 public liquidityFee           = 5; // Auto 0.5% $ YAK/WPLS LP
    uint256 public rewardFee              = 5; // 0.5% $PLSX Rewards
    uint256 public buyburnFee             = 15; // 0.5% Buy and Burn $X , 0.5% Buy and Burn $SURF, 0.5% Buy and Burn $PTGC
    uint256 public stakingFundFee         = 5; // 0.5% Staking Fund Fee
    uint256 public PropertyOverheadFee    = 5; // 0.5% Property Overhead Fee
    uint256 public LandDevelopmentFundFee = 10; // 1% Land Development Fund Fees
    uint256 public burnFee                = 5; // 0.5% burn $YAK
    uint256 public totalFee               = stakingFundFee + rewardFee + liquidityFee + PropertyOverheadFee + buyburnFee + LandDevelopmentFundFee;
    uint256 public feeDenominator         = 1000;

    uint256 public sellMultiplier  = 100;

    address public autoLiquidityReceiver;
    address public stakingFundFeeReceiver;
    address public LandDevelopmentFundFeeReceiver;
    address public PropertyOverheadFeeReceiver;

    uint256 targetLiquidity = 100;
    uint256 targetLiquidityDenominator = 100;

    IDEXRouter public router;
    address public pair;

    bool public tradingOpen = false;

    DividendDistributor public distributor;
    uint256 distributorGas = 2000000;

    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply * 10 / 10000; // 0.1% of supply
    bool inSwap;
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor (
        string memory tokenName, 
        string memory tokenSymbol, 
        uint8 tokenDecimals, 
        uint256 tokenTotalSupply
    ) Auth(msg.sender) {
        _name = tokenName;
        _symbol = tokenSymbol;
        _decimals = tokenDecimals; 
        _totalSupply = tokenTotalSupply.mul(10**uint256(tokenDecimals));
        swapThreshold = _totalSupply * 10 / 10000;
        router = IDEXRouter(0x165C3410fC91EF562C50559f7d2289fEbed552d9);
        pair = IDEXFactory(router.factory()).createPair(WPLS, address(this));
        _allowances[address(this)][address(router)] = type(uint256).max;

        distributor = new DividendDistributor(address(router));

        isFeeExempt[msg.sender] = true;

        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;

        autoLiquidityReceiver = msg.sender;
        stakingFundFeeReceiver = msg.sender;
        LandDevelopmentFundFeeReceiver = msg.sender;
        PropertyOverheadFeeReceiver = msg.sender;

        _balances[msg.sender] = _totalSupply;
        emit Transfer(address(0), msg.sender, _totalSupply);
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

        // Dividend tracker
        if(!isDividendExempt[sender]) {
            try distributor.setShare(sender, _balances[sender]) {} catch {}
        }

        if(!isDividendExempt[recipient]) {
            try distributor.setShare(recipient, _balances[recipient]) {} catch {} 
        }

        try distributor.process(distributorGas) {} catch {}

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
        IPRC20 token1 = IPRC20(0x12828D4cdA7CBfAcd7586E54708A9b9674641bEd); //SURF
        IPRC20 token2 = IPRC20(0xA6C4790cc7Aa22CA27327Cb83276F2aBD687B55b); //X
        IPRC20 token3 = IPRC20(0x94534EeEe131840b1c0F61847c572228bdfDDE93); //PTGC

        address[] memory path = new address[](2);
        path[0] = WPLS;
        path[1] = address(token1);

        address[] memory path2 = new address[](2);
        path2[0] = WPLS;
        path2[1] = address(token2);

        address[] memory path3 = new address[](2);
        path3[0] = WPLS;
        path3[1] = address(token3);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount/3}(
            0,
            path,
            address(this),
            block.timestamp
        );

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount/3}(
            0,
            path2,
            address(this),
            block.timestamp
        );
        
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount/3}(
            0,
            path3,
            address(this),
            block.timestamp
        );

        uint256 amount1 = token1.balanceOf(address(this));
        uint256 amount2 = token2.balanceOf(address(this));
        uint256 amount3 = token3.balanceOf(address(this));

        token1.transfer(address(0x0000000000000000000000000000000000000369), amount1);
        token2.transfer(address(0x0000000000000000000000000000000000000369), amount2);
        token3.transfer(address(0x0000000000000000000000000000000000000369), amount3);
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
        uint256 amountPLSReflection = amountPLS.mul(rewardFee).div(totalPLSFee);
        uint256 amountPLSBuyburn = amountPLS.mul(buyburnFee).div(totalPLSFee);
        uint256 amountPLSStakingFund = amountPLS.mul(stakingFundFee).div(totalPLSFee);
        uint256 amountPLSLandDevelopmentFund = amountPLS.mul(LandDevelopmentFundFee).div(totalPLSFee);
        uint256 amountPLSPropertyOverhead = amountPLS.mul(PropertyOverheadFee).div(totalPLSFee);

        try distributor.deposit{value: amountPLSReflection}() {} catch {}

        if (amountPLSBuyburn > 0) {
            buyburn(amountPLSBuyburn);
        }

        (bool tmpSuccess,) = payable(stakingFundFeeReceiver).call{value: amountPLSStakingFund, gas: 30000}("");
        (tmpSuccess,) = payable(LandDevelopmentFundFeeReceiver).call{value: amountPLSLandDevelopmentFund, gas: 30000}("");
        
        // Supress warning msg
        tmpSuccess = false;

        addPLSLp(amountToLiquify,amountPLSLiquidity);

        uint256 remainder = address(this).balance - amountPLSPropertyOverhead;

        (bool tmpSuccess2,) = payable(PropertyOverheadFeeReceiver).call{value: amountPLSPropertyOverhead+remainder, gas: 30000}("");
        // Supress warning msg
        tmpSuccess2 = false;
    }

    function setIsDividendExempt(address holder, bool exempt) external authorized {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt){
            distributor.setShare(holder, 0);
        }else{
            distributor.setShare(holder, _balances[holder]);
        }
    }

    function setIsFeeExempt(address holder, bool exempt) external authorized {
        isFeeExempt[holder] = exempt;
    }

    function setFees(uint256 _liquidityFee, uint256 _rewardFee, uint256 _stakingFundFee, uint256 _LandDevelopmentFundFee, uint256 _PropertyOverheadFee, uint256 _burnFee, uint256 _buyburnFee) external authorized {
        liquidityFee = _liquidityFee;
        rewardFee = _rewardFee;
        stakingFundFee = _stakingFundFee;
        LandDevelopmentFundFee = _LandDevelopmentFundFee;
        PropertyOverheadFee = _PropertyOverheadFee;
        burnFee = _burnFee;
        buyburnFee = _buyburnFee;
        uint256 subtotalFee = _liquidityFee.add(_rewardFee).add(_stakingFundFee).add(_LandDevelopmentFundFee);
        totalFee = subtotalFee.add(_PropertyOverheadFee).add(_buyburnFee);
        feeDenominator = 1000;
        require(totalFee < 55, "Fees cannot be more than 5%");
    }

    function liftoff() public onlyOwner {
        require(notliftoff, "Moon mission already a go");
        tradingOpen = true;

        notliftoff = false;
    }

    function setFeeReceivers(address _autoLiquidityReceiver, address _stakingFundFeeReceiver, address _LandDevelopmentFundFeeReceiver, address _PropertyOverheadFeeReceiver ) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        stakingFundFeeReceiver = _stakingFundFeeReceiver;
        LandDevelopmentFundFeeReceiver = _LandDevelopmentFundFeeReceiver;
        PropertyOverheadFeeReceiver = _PropertyOverheadFeeReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount) external authorized {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator) external authorized {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external authorized {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setDistributorSettings(uint256 gas) external authorized {
        distributorGas = gas;
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

event AutoLiquify(uint256 amountPLS, uint256 amountBOG);

}