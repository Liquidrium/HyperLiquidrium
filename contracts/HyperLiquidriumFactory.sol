// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import {IUniswapV3Factory} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {HyperLiquidrium} from './HyperLiquidrium.sol';

contract HyperLiquidriumFactory is Ownable {
    IUniswapV3Factory public uniswapV3Factory;
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
    ) external onlyOwner returns (address hyperliquidrium) {
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
