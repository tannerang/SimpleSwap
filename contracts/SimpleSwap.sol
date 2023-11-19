// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { ISimpleSwap } from "./interface/ISimpleSwap.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract SimpleSwap is ISimpleSwap, ERC20 {
    
    using SafeMath for uint;
    
    address public immutable tokenA;
    address public immutable tokenB;
    uint public reserveA;
    uint public reserveB;
    uint private _unlocked = 1;
    
    modifier lock() {
        require(_unlocked == 1, "SimpleSwap: LOCKED");
        _unlocked = 0;
        _;
        _unlocked = 1;
    }

    constructor(address _tokenA, address _tokenB) ERC20("SimpleSwapToken", "SSTK") {
        require(_tokenA.code.length > 0, "SimpleSwap: TOKENA_IS_NOT_CONTRACT");
        require(_tokenB.code.length > 0, "SimpleSwap: TOKENB_IS_NOT_CONTRACT");
        require(_tokenA != _tokenB, "SimpleSwap: TOKENA_TOKENB_IDENTICAL_ADDRESS");
        (address token0, address token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
        require(token0 < token1, "SimpleSwap: TOKENA_SHOULD_BE_LESS_THAN_TOKENB");
        (tokenA, tokenB) = (token0, token1);
    }

    /// @notice Swap tokenIn for tokenOut with amountIn
    /// @param tokenIn The address of the token to swap from
    /// @param tokenOut The address of the token to swap to
    /// @param amountIn The amount of tokenIn to swap
    /// @return amountOut The amount of tokenOut received
    function swap(
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn
    ) external virtual override returns (uint256 amountOut) {
        require((tokenIn == tokenA || tokenIn == tokenB), "SimpleSwap: INVALID_TOKEN_IN");
        require((tokenOut == tokenA || tokenOut == tokenB), "SimpleSwap: INVALID_TOKEN_OUT");
        require(tokenIn != tokenOut, "SimpleSwap: IDENTICAL_ADDRESS");
        require(amountIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        uint256 reserveIn;
        uint256 reserveOut;
        
        (uint256 _reserve0, uint256 _reserve1) = this.getReserves(); // gas savings
        if (tokenIn == tokenA) {
            (reserveIn, reserveOut) = (_reserve0, _reserve1);
            amountOut = amountIn * reserveOut / (reserveIn + amountIn);
            if (amountOut > 0) {
                require(amountOut <= _reserve1, "SimpleSwap: INSUFFICIENT_TOKENA_LIQUIDITY");
                ERC20(tokenOut).transfer(msg.sender, amountOut);
                ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
                _updateReserve((reserveA + amountIn), (reserveB - amountOut));
            }
        } else {
            (reserveIn, reserveOut) = (_reserve1, _reserve0);
            amountOut = amountIn * reserveOut / (reserveIn + amountIn);
            if (amountOut > 0) {
                require(amountOut <= _reserve0, "SimpleSwap: INSUFFICIENT_TOKENB_LIQUIDITY");
                ERC20(tokenOut).transfer(msg.sender, amountOut);
                ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
                _updateReserve((reserveA - amountOut), (reserveB + amountIn));
            }
        }
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
    }
 
    /// @notice Add liquidity to the pool
    /// @param amountAIn The amount of tokenA to add
    /// @param amountBIn The amount of tokenB to add
    /// @return amountA The actually amount of tokenA added
    /// @return amountB The actually amount of tokenB added
    /// @return liquidity The amount of liquidity minted
    function addLiquidity(
        uint256 amountAIn,
        uint256 amountBIn
    ) external virtual override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (uint _reserveA, uint _reserveB) = this.getReserves();
        if (_reserveA == 0 && _reserveB == 0) {
            (amountA, amountB) = (amountAIn, amountBIn);
        } else {
            uint amountBOptimal = _quote(amountAIn, _reserveA, _reserveB);
            if (amountBOptimal <= amountBIn) {
                require(amountBOptimal >= 0, "SimpleSwap: INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountAIn, amountBOptimal);
            } else {
                uint amountAOptimal = _quote(amountBIn, _reserveB, _reserveA);
                assert(amountAOptimal <= amountAIn);
                require(amountAOptimal >= 0, "SimpleSwap: INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBIn);
            }
        }
        
        ERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        ERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        liquidity = this.mint(msg.sender);
        emit AddLiquidity(msg.sender, amountA, amountB, liquidity);

        return (amountA, amountB, liquidity);
    }

    /// @notice Remove liquidity from the pool
    /// @param liquidity The amount of liquidity to remove
    /// @return amountA The amount of tokenA received
    /// @return amountB The amount of tokenB received
    function removeLiquidity(uint256 liquidity) external virtual override returns (uint256 amountA, uint256 amountB) {
        this.transferFrom(msg.sender, address(this), liquidity);  // send liquidity to pair
        (uint amount0, uint amount1) = this.burn(msg.sender);
        emit RemoveLiquidity(msg.sender, amount0, amount1, liquidity);

        return (amount0, amount1);
    }

    function burn(address to) external lock returns (uint amount0, uint amount1) {
        address _token0 = tokenA;
        address _token1 = tokenB;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        uint256 _totalSupply = totalSupply();

        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);

        ERC20(_token0).transfer(to, amount0);
        ERC20(_token1).transfer(to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _updateReserve(balance0, balance1);

        return (amount0, amount1);
    }

    function mint(address to) external lock returns (uint liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = this.getReserves();
        uint256 balance0 = IERC20(tokenA).balanceOf(address(this));
        uint256 balance1 = IERC20(tokenB).balanceOf(address(this));
        uint256 amount0 = balance0.sub(_reserve0);
        uint256 amount1 = balance1.sub(_reserve1);
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        _mint(to, liquidity);
        _updateReserve(balance0, balance1);

        return liquidity;
    }

    /// @notice Get the reserves of the pool
    /// @return reserveA The reserve of tokenA
    /// @return reserveB The reserve of tokenB
    function getReserves() external view virtual override returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    /// @notice Get the address of tokenA
    /// @return tokenA The address of tokenA
    function getTokenA() external view virtual override returns (address) {
        return tokenA;
    }

    /// @notice Get the address of tokenB
    /// @return tokenB The address of tokenB
    function getTokenB() external view virtual override returns (address) {
        return tokenB;
    }

    function _quote(uint _amountA, uint _reserveA, uint _reserveB) internal pure returns (uint _amountB) {
        require(_amountA > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(_reserveA > 0 && _reserveB > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY");
        _amountB = _amountA.mul(_reserveB) / _reserveA;

        return _amountB;
    }

    function _updateReserve(uint _reserveA, uint _reserveB) private {
        reserveA = _reserveA;
        reserveB = _reserveB;
    }
}
