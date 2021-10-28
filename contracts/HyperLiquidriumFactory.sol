// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import {IUniswapV3Factory} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {HyperLiquidrium} from './HyperLiquidrium.sol';

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

contract HyperLiquidriumFactory is Ownable {
    IUniswapV3Factory public immutable uniswapV3Factory;
    mapping(address => mapping(address => mapping(uint24 => address))) public getHyperLiquidrium; // toke0, token1, fee -> hyperliquidrium address
    address[] public allHyperLiquidriums;

    event HyperLiquidriumCreated(address token0, address token1, uint24 fee, address hyperliquidrium, uint256);

    constructor(address _uniswapV3Factory) {
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
    }

    function allHyperLiquidriumsLength() external view returns (uint256) {
        return allHyperLiquidriums.length;
    }

    function createHyperLiquidrium(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external nonReentrant onlyOwner returns (address hyperliquidrium) {
        require(tokenA != tokenB, 'SF: IDENTICAL_ADDRESSES'); // TODO: using PoolAddress library (uniswap-v3-periphery)
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'SF: ZERO_ADDRESS');
        require(getHyperLiquidrium[token0][token1][fee] == address(0), 'SF: HyperLiquidrium_EXISTS');
        int24 tickSpacing = uniswapV3Factory.feeAmountTickSpacing(fee);
        require(tickSpacing != 0, 'SF: INCORRECT_FEE');
        address pool = uniswapV3Factory.getPool(token0, token1, fee);
        if (pool == address(0)) {
            pool = uniswapV3Factory.createPool(token0, token1, fee);
        }
        hyperliquidrium = address(
            new HyperLiquidrium{salt: keccak256(abi.encodePacked(token0, token1, fee, tickSpacing))}(pool, owner())
        );

        getHyperLiquidrium[token0][token1][fee] = hyperliquidrium;
        getHyperLiquidrium[token1][token0][fee] = hyperliquidrium; // populate mapping in the reverse direction
        allHyperLiquidriums.push(hyperliquidrium);
        emit HyperLiquidriumCreated(token0, token1, fee, hyperliquidrium, allHyperLiquidriums.length);
    }
}
