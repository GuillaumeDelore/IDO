// SPDX-License-Identifier: UNLICENSED

pragma solidity =0.8.9;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";


interface IUniswapV2Router02 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface ILendFlareToken is IERC20 {
    function setLiquidityFinish() external;
}




contract LiquidityTransformer is ReentrancyGuard {
    using Address for address payable;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    ILendFlareToken public lendflareToken; //declaration of lendflare token used during the IDO
    address public uniswapPair; //adress of the token-weth pair on uniswap

    IUniswapV2Router02 public constant uniswapRouter =
        IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); //declaration of the router 

    address payable teamAddress; //team address

    uint256 public constant FEE_DENOMINATOR = 10; // Percentage kept in reserve
    uint256 public constant liquifyTokens = 909090909 * 1e18; // part of tokens that are liquid
    uint256 public investmentTime; //duration of IDO
    uint256 public minInvest; // minimum investment
    uint256 public launchTime; // timestamp launch time

    struct Globals {
        uint256 totalUsers;
        uint256 totalBuys;
        uint256 transferredUsers;
        uint256 totalWeiContributed;
        bool liquidity;
        uint256 endTimeAt;
    } //data of IDO

    Globals public globals; //declaration of IDO data

    mapping(address => uint256) public investorBalances; //dictionnary of all deposits per users
    mapping(address => uint256[2]) investorHistory; //dictionnary of all deposits per users

    event UniSwapResult(
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity,
        uint256 endTimeAt
    ); //amount of funds generated

    modifier afterUniswapTransfer() {
        require(globals.liquidity == true, "Forward liquidity first");
        _;
    } //modifier for globals object. Assert the fund haven been deposited on uniswap.

    constructor(
        address _lendflareToken,
        address payable _teamAddress,
        uint256 _launchTime
    ) {
        require(_launchTime > block.timestamp, "!_launchTime");
        launchTime = _launchTime;
        lendflareToken = ILendFlareToken(_lendflareToken);
        teamAddress = _teamAddress;

        minInvest = 0.1 ether;
        investmentTime = 7 days;
        
    }


    function createPair() external { //create pair on uniswap
        require(address(uniswapPair) == address(0), "!uniswapPair"); //check that uniswap pair is null adress and so has not been udpated by the contract.

        uniswapPair = address(
            IUniswapV2Factory(factory()).createPair(
                WETH(),
                address(lendflareToken)
            )
        );
    }

    receive() external payable {
        require(
            msg.sender == address(uniswapRouter) || msg.sender == teamAddress,
            "Direct deposits disabled"
        );
    }

    function reserve() external payable {
        _reserve(msg.sender, msg.value);
    } //call function _reserve to add user eth contribution to the IDO. (only if this user did a initial contribution in eth, not in tokens)

    function reserveWithToken(address _tokenAddress, uint256 _tokenAmount)
        external
    {
        IERC20 token = IERC20(_tokenAddress);

        token.safeTransferFrom(msg.sender, address(this), _tokenAmount);

        token.approve(address(uniswapRouter), _tokenAmount);

        address[] memory _path = preparePath(_tokenAddress);

        uint256[] memory amounts = uniswapRouter.swapExactTokensForETH(
            _tokenAmount,
            minInvest,
            _path,
            address(this),
            block.timestamp
        );

        _reserve(msg.sender, amounts[1]);
    } //call function _reserve if the user deposit is a token deposit.

    function _reserve(address _senderAddress, uint256 _senderValue) internal {
        require(block.timestamp >= launchTime, "Not started");
        require(
            block.timestamp <= launchTime.add(investmentTime),
            "IDO has ended"
        );
        require(globals.liquidity == false, "!globals.liquidity");
        require(_senderValue >= minInvest, "Investment below minimum");

        if (investorBalances[_senderAddress] == 0) {
            globals.totalUsers++;
        }

        investorBalances[_senderAddress] = investorBalances[_senderAddress].add(
            _senderValue
        );

        globals.totalWeiContributed = globals.totalWeiContributed.add(
            _senderValue
        );
        globals.totalBuys++;
    } //_reserve update IDO global contribution and user contribution

    function forwardLiquidity() external nonReentrant {
        require(msg.sender == tx.origin, "!EOA");
        require(globals.liquidity == false, "!globals.liquidity");
        require(
            block.timestamp > launchTime.add(investmentTime),
            "Not over yet"
        );

        uint256 _etherFee = globals.totalWeiContributed.div(FEE_DENOMINATOR); //amount kept as team reserves
        uint256 _balance = globals.totalWeiContributed.sub(_etherFee); //amount kept as liquidity

        teamAddress.sendValue(_etherFee);// amount sent to team adress

        uint256 half = liquifyTokens.div(2); // total initial supply of tokens divided by two.
        uint256 _lendflareTokenFee = half.div(FEE_DENOMINATOR); // part of initial supply kept in reserve

        IERC20(lendflareToken).safeTransfer(teamAddress, _lendflareTokenFee); //tranfer of _lendflareTokenfee amount to teamAdress

        lendflareToken.approve(
            address(uniswapRouter),
            half.sub(_lendflareTokenFee)
        );// approve of tokens for swap on Uniswap

        (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        ) = uniswapRouter.addLiquidityETH{value: _balance}(
                address(lendflareToken),
                half.sub(_lendflareTokenFee),
                0,
                0,
                address(0x0),
                block.timestamp
            );//creation of the liquidity on Uniswap. Ownership to 0x0 address.

        globals.liquidity = true; //bool variable to confirm liquidity has been added on Uniswap.
        globals.endTimeAt = block.timestamp; //timestamp

        lendflareToken.setLiquidityFinish(); //call interface function from lendlfare token contract

        emit UniSwapResult(
            amountToken,
            amountETH,
            liquidity,
            globals.endTimeAt
        ); //emit event
    }

    function getMyTokens() external afterUniswapTransfer nonReentrant {
        require(globals.liquidity, "!globals.liquidity");
        require(investorBalances[msg.sender] > 0, "!balance");

        uint256 myTokens = checkMyTokens(msg.sender);

        investorHistory[msg.sender][0] = investorBalances[msg.sender];
        investorHistory[msg.sender][1] = myTokens;
        investorBalances[msg.sender] = 0;

        IERC20(lendflareToken).safeTransfer(msg.sender, myTokens);

        globals.transferredUsers++;

        if (globals.transferredUsers == globals.totalUsers) {
            uint256 surplusBalance = IERC20(lendflareToken).balanceOf(
                address(this)
            );

            if (surplusBalance > 0) {
                IERC20(lendflareToken).safeTransfer(
                    0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
                    surplusBalance
                );
            }
        }
    }// get user token after IDO

    /* view functions */
    function WETH() public pure returns (address) {
        return IUniswapV2Router02(uniswapRouter).WETH();
    }// get weth adress from Uniswap

    function checkMyTokens(address _sender) public view returns (uint256) {
        if (
            globals.totalWeiContributed == 0 || investorBalances[_sender] == 0
        ) {
            return 0;
        }

        uint256 half = liquifyTokens.div(2);
        uint256 otherHalf = liquifyTokens.sub(half);
        uint256 percent = investorBalances[_sender].mul(100e18).div(
            globals.totalWeiContributed
        );
        uint256 myTokens = otherHalf.mul(percent).div(100e18);

        return myTokens;
    }// get tokens available for withdraw

    function factory() public pure returns (address) {
        return IUniswapV2Router02(uniswapRouter).factory();
    }// return uniswap factory adress

    function getInvestorHistory(address _sender)
        public
        view
        returns (uint256[2] memory)
    {
        return investorHistory[_sender];
    }// get amount that have been provided by users

    function preparePath(address _tokenAddress)
        internal
        pure
        returns (address[] memory _path)
    {
        _path = new address[](2);
        _path[0] = _tokenAddress;
        _path[1] = WETH();
    }// path used for the funding swap on Uniswap
}