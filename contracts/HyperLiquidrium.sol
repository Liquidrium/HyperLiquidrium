// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "../interfaces/IVault.sol";
import "../interfaces/IUniversalVault.sol";


/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// @title HyperLiquidrium
// @notice A Uniswap V2-like interface with fungible liquidity to Uniswap V3
// which allows for arbitrary liquidity provision: one-sided, lop-sided, and
// balanced.
contract HyperLiquidrium is IVault, IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    address public owner;

    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;

    // The following three variables server the very important purpose of
    // limiting inventory risk and the arbitrage opportunities made possible by
    // our instant deposit & withdrawal.
    // If, in the ETHUSDT pool at an ETH price of 2500 USDT, I deposit 100k
    // USDT in a pool with 40 WETH, and then directly afterwards withdraw 50k
    // USDT and 20 WETH (this is of equivalent dollar value), I drastically
    // change the pool composition and additionally decreases deployed capital
    // by 50%. Keeping a maxTotalSupply just above our current total supply
    // means that large amounts of funds can't be deposited all at once to
    // create a large imbalance of funds or to sideline many funds.
    // Additionally, deposit maximums prevent users from using the pool as
    // a counterparty to trade assets against while avoiding uniswap fees
    // & slippage--if someone were to try to do this with a large amount of
    // capital they would be overwhelmed by the gas fees necessary to call
    // deposit & withdrawal many times.
    uint256 public deposit0Max;
    uint256 public deposit1Max;
    uint256 public maxTotalSupply;

    uint256 constant public PRECISION = 1e36;


    event NewMaxSupply(uint256 newSupply);
    event TokensDepositMax(uint256 token0Max, uint256 token1Max);


    // @param _pool Uniswap V3 pool for which liquidity is managed
    // @param _owner Owner of the HyperLiquidrium
    constructor(
        address _pool,
        address _owner
    ) ERC20("Fungible Liquidity", "LIQ") {
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        owner = _owner;

        maxTotalSupply = 0; // no cap
        deposit0Max = uint256(-1); // max uint256
        deposit1Max = uint256(-1); // max uint256
    }

    // @notice Distributes shares to depositor equal to the token1 value of his
    // deposit multiplied by the ratio of total liquidity shares issued divided
    // by the pool's AUM measured in token1 value.
    // @param deposit0 Amount of token0 transfered from sender to HyperLiquidrium
    // @param deposit1 Amount of token0 transfered from sender to HyperLiquidrium
    // @param to Address to which liquidity tokens are minted
    // @return shares Quantity of liquidity tokens minted as a result of deposit
    function deposit(
        uint256 deposit0,
        uint256 deposit1,
        address to
    ) external nonReentrant override returns (uint256 shares) {
        require(deposit0 > 0 || deposit1 > 0, "deposits must be nonzero");
        require(deposit0 < deposit0Max && deposit1 < deposit1Max, "deposits must be less than maximum amounts");
        require(to != address(0) && to != address(this), "to");

        // update fees for inclusion in total pool amounts
        (uint128 baseLiquidity,,) = _position(baseLower, baseUpper);
        if (baseLiquidity > 0) {
            pool.burn(baseLower, baseUpper, 0);
        }
        (uint128 limitLiquidity,,)  = _position(limitLower, limitUpper);
        if (limitLiquidity > 0) {
            pool.burn(limitLower, limitUpper, 0);
        }

        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(currentTick());
        uint256 price = FullMath.mulDiv(uint256(sqrtPrice).mul(uint256(sqrtPrice)), PRECISION, 2**(96 * 2));

        (uint256 pool0, uint256 pool1) = getTotalAmounts();

        uint256 deposit0PricedInToken1 = deposit0.mul(price).div(PRECISION);
        shares = deposit1.add(deposit0PricedInToken1);

        if (deposit0 > 0) {
          token0.safeTransferFrom(msg.sender, address(this), deposit0);
        }
        if (deposit1 > 0) {
          token1.safeTransferFrom(msg.sender, address(this), deposit1);
        }

        if (totalSupply() != 0) {
          uint256 pool0PricedInToken1 = pool0.mul(price).div(PRECISION);
          shares = shares.mul(totalSupply()).div(pool0PricedInToken1.add(pool1));
        }
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, deposit0, deposit1);
        // Check total supply cap not exceeded. A value of 0 means no limit.
        require(maxTotalSupply == 0 || totalSupply() <= maxTotalSupply, "maxTotalSupply");
    }

    // @notice Redeems shares by sending out a percentage of the HyperLiquidrium's
    // AUM--this percentage is equal to the percentage of total issued shares
    // represented by the redeeemed shares.
    // @param shares Number of liquidity tokens to redeem as pool assets
    // @param to Address to which redeemed pool assets are sent
    // @param from Address from which liquidity tokens are sent
    // @return amount0 Amount of token0 redeemed by the submitted liquidity tokens
    // @return amount1 Amount of token1 redeemed by the submitted liquidity tokens
    function withdraw(
        uint256 shares,
        address to,
        address from
    ) external nonReentrant override returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0), "to");
        require(from == msg.sender || IUniversalVault(from).owner() == msg.sender, "Sender must own the tokens");

        // Withdraw liquidity from Uniswap pool
        (uint256 base0, uint256 base1) =
            _burnLiquidity(baseLower, baseUpper, _liquidityForShares(baseLower, baseUpper, shares), to, false);
        (uint256 limit0, uint256 limit1) =
            _burnLiquidity(limitLower, limitUpper, _liquidityForShares(limitLower, limitUpper, shares), to, false);

        // Push tokens proportional to unused balances
        uint256 totalSupply = totalSupply();
        uint256 unusedAmount0 = token0.balanceOf(address(this)).mul(shares).div(totalSupply);
        uint256 unusedAmount1 = token1.balanceOf(address(this)).mul(shares).div(totalSupply);
        if (unusedAmount0 > 0) token0.safeTransfer(to, unusedAmount0);
        if (unusedAmount1 > 0) token1.safeTransfer(to, unusedAmount1);

        amount0 = base0.add(limit0).add(unusedAmount0);
        amount1 = base1.add(limit1).add(unusedAmount1);

        _burn(from, shares);

        emit Withdraw(from, to, shares, amount0, amount1);
    }

    // @notice Updates HyperLiquidrium's LP positions.
    // @dev The base position is placed first with as much liquidity as
    // possible and is typically symmetric around the current price. This order
    // should use up all of one token, leaving some unused quantity of the
    // other. This unused amount is then placed as a single-sided order.
    // @param _baseLower The lower tick of the base position
    // @param _baseUpper The upper tick of the base position
    // @param _limitLower The lower tick of the limit position
    // @param _limitUpper The upper tick of the limit position
    // @param feeRecipient Address of recipient of 10% of earned fees since last rebalance
    // @param swapQuantity Quantity of tokens to swap; if quantity is positive,
    // `swapQuantity` token0 are swaped for token1, if negative, `swapQuantity`
    // token1 is swaped for token0
    function rebalance(
        int24 _baseLower,
        int24 _baseUpper,
        int24 _limitLower,
        int24 _limitUpper,
        address feeRecipient,
        int256 swapQuantity
    ) external nonReentrant override onlyOwner {
        require(_baseLower < _baseUpper && _baseLower % tickSpacing == 0 && _baseUpper % tickSpacing == 0,
                "base position invalid");
        require(_limitLower < _limitUpper && _limitLower % tickSpacing == 0 && _limitUpper % tickSpacing == 0,
                "limit position invalid");

        // update fees
        (uint128 baseLiquidity,,) = _position(baseLower, baseUpper);
        if (baseLiquidity > 0) {
            pool.burn(baseLower, baseUpper, 0);
        }
        (uint128 limitLiquidity,,)  = _position(limitLower, limitUpper);
        if (limitLiquidity > 0) {
            pool.burn(limitLower, limitUpper, 0);
        }

        // Withdraw all liquidity and collect all fees from Uniswap pool
        (, uint256 feesLimit0, uint256 feesLimit1) = _position(baseLower, baseUpper);
        (, uint256 feesBase0, uint256 feesBase1)  = _position(limitLower, limitUpper);

        uint256 fees0 = feesBase0.add(feesLimit0);
        uint256 fees1 = feesBase1.add(feesLimit1);
        _burnLiquidity(baseLower, baseUpper, baseLiquidity, address(this), true);
        _burnLiquidity(limitLower, limitUpper, limitLiquidity, address(this), true);

        // transfer 15% of fees for Liquidrium buybacks
        if(fees0 > 0) token0.safeTransfer(feeRecipient, fees0.mul(3).div(20)); 
        if(fees1 > 0) token1.safeTransfer(feeRecipient, fees1.mul(3).div(20));

        emit Rebalance(
            currentTick(),
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            fees0,
            fees1,
            totalSupply()
        );

        // swap tokens if required
        if (swapQuantity != 0) {
            pool.swap(
                address(this),
                swapQuantity > 0,
                swapQuantity > 0 ? swapQuantity : -swapQuantity,
                swapQuantity > 0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                abi.encode(address(this))
            );
        }

        baseLower = _baseLower;
        baseUpper = _baseUpper;
        baseLiquidity = _liquidityForAmounts(
            baseLower,
            baseUpper,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
        _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

        limitLower = _limitLower;
        limitUpper = _limitUpper;
        limitLiquidity = _liquidityForAmounts(
            limitLower,
            limitUpper,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
        _mintLiquidity(limitLower, limitUpper, limitLiquidity, address(this));
    }

    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address payer
    ) internal returns (uint256 amount0, uint256 amount1) {
      if (liquidity > 0) {
            (amount0, amount1) = pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(payer)
            );
        }
    }

    function _burnLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        bool collectAll
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity > 0) {
            // Burn liquidity
            (uint256 owed0, uint256 owed1) = pool.burn(tickLower, tickUpper, liquidity);

            // Collect amount owed
            uint128 collect0 = collectAll ? type(uint128).max : _uint128Safe(owed0);
            uint128 collect1 = collectAll ? type(uint128).max : _uint128Safe(owed1);
            if (collect0 > 0 || collect1 > 0) {
                (amount0, amount1) = pool.collect(to, tickLower, tickUpper, collect0, collect1);
            }
        }
    }

    function _liquidityForShares(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares
    ) internal view returns (uint128) {
        (uint128 position,,) = _position(tickLower, tickUpper);
        return _uint128Safe(uint256(position).mul(shares).div(totalSupply()));
    }

    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1)
    {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liquidity, , , tokensOwed0, tokensOwed1) = pool.positions(positionKey);
    }

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool), "not pool");
        address payer = abi.decode(data, (address));

        if (payer == address(this)) {
            if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
            if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        } else {
            if (amount0 > 0) token0.safeTransferFrom(payer, msg.sender, amount0);
            if (amount1 > 0) token1.safeTransferFrom(payer, msg.sender, amount1);
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool), "not pool");
        address payer = abi.decode(data, (address));

        if (amount0Delta > 0) {
            if (payer == address(this)) {
                token0.safeTransfer(msg.sender, uint256(amount0Delta));
            } else {
                token0.safeTransferFrom(payer, msg.sender, uint256(amount0Delta));
            }
        } else if (amount1Delta > 0) {
            if (payer == address(this)) {
                token1.safeTransfer(msg.sender, uint256(amount1Delta));
            } else {
                token1.safeTransferFrom(payer, msg.sender, uint256(amount1Delta));
            }
        }
    }

    // @return total0 Quantity of token0 in both positions and unused in the HyperLiquidrium
    // @return total1 Quantity of token1 in both positions and unused in the HyperLiquidrium
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (, uint256 base0, uint256 base1) = getBasePosition();
        (, uint256 limit0, uint256 limit1) = getLimitPosition();
        total0 = token0.balanceOf(address(this)).add(base0).add(limit0);
        total1 = token1.balanceOf(address(this)).add(base1).add(limit1);
    }

    // @return liquidity Amount of total liquidity in the base position
    // @return amount0 Estimated amount of token0 that could be collected by
    // burning the base position
    // @return amount1 Estimated amount of token1 that could be collected by
    // burning the base position
    function getBasePosition()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint128 positionLiquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _position(baseLower, baseUpper);
        (amount0, amount1) = _amountsForLiquidity(baseLower, baseUpper, positionLiquidity);
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
        liquidity = positionLiquidity;
    }

    // @return liquidity Amount of total liquidity in the limit position
    // @return amount0 Estimated amount of token0 that could be collected by
    // burning the limit position
    // @return amount1 Estimated amount of token1 that could be collected by
    // burning the limit position
    function getLimitPosition()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint128 positionLiquidity, uint128 tokensOwed0, uint128 tokensOwed1) = _position(limitLower, limitUpper);
        (amount0, amount1) = _amountsForLiquidity(limitLower, limitUpper, positionLiquidity);
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
        liquidity = positionLiquidity;
    }

    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    function _liquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0,
                amount1
            );
    }

    function currentTick() public view returns (int24 tick) {
        int24 _tick = getTwap();
        return _tick;
    }

        /// @dev Fetches time-weighted average price in ticks from Uniswap pool.
    function getTwap() public view returns (int24) {
        uint32 _twapDuration = 60; // 60 seconds
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = _twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / _twapDuration);
    }

    function _uint128Safe(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    // @param _maxTotalSupply The maximum liquidity token supply the contract allows
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyOwner {
        maxTotalSupply = _maxTotalSupply;
        emit NewMaxSupply(_maxTotalSupply);
    }

    // @param _deposit0Max The maximum amount of token0 allowed in a deposit
    // @param _deposit1Max The maximum amount of token1 allowed in a deposit
    function setDepositMax(uint256 _deposit0Max, uint256 _deposit1Max) external onlyOwner {
        deposit0Max = _deposit0Max;
        deposit1Max = _deposit1Max;
        emit TokensDepositMax(_deposit0Max, _deposit1Max);
    }

    modifier onlyOwner {
        require(msg.sender == owner, "only owner");
        _;
    }
}
