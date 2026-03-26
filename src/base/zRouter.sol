// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev uniV2 / uniV3 / uniV4 / zAMM
///      multi-amm multi-call router
///      optimized with simple abi.
///      This version is for Base.
///      Also includes Aerodrome.
contract zRouter {
    error BadSwap();
    error Expired();
    error Slippage();
    error InvalidId();
    error Unauthorized();
    error InvalidMsgVal();
    error ETHTransferFailed();

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, Expired());
        _;
    }

    constructor() payable {}

    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut);
        (uint112 r0, uint112 r1,) = IV2Pool(pool).getReserves();
        (uint256 resIn, uint256 resOut) = zeroForOne ? (r0, r1) : (r1, r0);

        unchecked {
            if (exactOut) {
                amountOut = swapAmount; // target
                uint256 n = resIn * amountOut * 1000;
                uint256 d = (resOut - amountOut) * 997;
                amountIn = (n + d - 1) / d; // ceil-div
                require(amountLimit == 0 || amountIn <= amountLimit, Slippage());
            } else {
                amountIn = swapAmount;
                amountOut = (amountIn * 997 * resOut) / (resIn * 1000 + amountIn * 997);
                require(amountLimit == 0 || amountOut >= amountLimit, Slippage());
            }
            if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
                if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                    safeTransfer(tokenIn, pool, amountIn);
                } else if (ethIn) {
                    wrapETH(pool, amountIn);
                    if (to != address(this)) {
                        if (msg.value > amountIn) {
                            _safeTransferETH(msg.sender, msg.value - amountIn);
                        }
                    }
                } else {
                    safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
                }
            }
        }

        if (zeroForOne) {
            IV2Pool(pool).swap(0, amountOut, ethOut ? address(this) : to, "");
        } else {
            IV2Pool(pool).swap(amountOut, 0, ethOut ? address(this) : to, "");
        }

        if (ethOut) {
            unwrapETH(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            depositFor(tokenOut, 0, amountOut, to); // marks output target
        }
    }

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _v3PoolFor(tokenIn, tokenOut, swapFee);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

        unchecked {
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(
                        ethIn, ethOut, false, msg.sender, tokenIn, tokenOut, to, swapFee
                    )
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // ── return values ────────────────────────────────
            // ── translate pool deltas to user-facing amounts ─
            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);

            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            } else if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to); // marks output target
            }
        }
    }

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut) = abi.decode(
            IV4PoolManager(V4_POOL_MANAGER)
                .unlock(
                    abi.encode(
                        msg.sender,
                        to,
                        exactOut,
                        swapFee,
                        tickSpace,
                        tokenIn,
                        tokenOut,
                        swapAmount,
                        amountLimit
                    )
                ),
            (uint256, uint256)
        );
        depositFor(tokenOut, 0, amountOut, to); // marks output target
    }

    // ** V4 ROUTER HELPER - HELPS WITH HOOKS AND MULTIHOPS:

    function swapV4Router(
        bytes calldata data,
        uint256 deadline,
        uint256 ethIn,
        address tokenOut,
        uint256 amountOut
    ) public payable returns (int256 delta) {
        delta = IV4Router(V4_ROUTER).swap{value: ethIn}(data, deadline);
        if (amountOut != 0) depositFor(tokenOut, 0, amountOut, address(this));
    }

    /// @dev Handle V4 PoolManager swap callback - hookless default.
    function unlockCallback(bytes calldata callbackData)
        public
        payable
        returns (bytes memory result)
    {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        (
            address payer,
            address to,
            bool exactOut,
            uint24 swapFee,
            int24 tickSpace,
            address tokenIn,
            address tokenOut,
            uint256 swapAmount,
            uint256 amountLimit
        ) = abi.decode(
            callbackData,
            (address, address, bool, uint24, int24, address, address, uint256, uint256)
        );

        bool zeroForOne = tokenIn < tokenOut;
        bool ethIn = tokenIn == address(0);

        V4PoolKey memory key = V4PoolKey(
            zeroForOne ? tokenIn : tokenOut,
            zeroForOne ? tokenOut : tokenIn,
            swapFee,
            tickSpace,
            address(0)
        );

        unchecked {
            int256 delta = _swap(swapAmount, key, zeroForOne, exactOut);
            uint256 takeAmount = zeroForOne
                ? (!exactOut
                        ? uint256(uint128(delta.amount1()))
                        : uint256(uint128(-delta.amount0())))
                : (!exactOut
                        ? uint256(uint128(delta.amount0()))
                        : uint256(uint128(-delta.amount1())));

            IV4PoolManager(msg.sender).sync(tokenIn);
            uint256 amountIn = !exactOut ? swapAmount : takeAmount;

            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                if (tokenIn != address(0)) {
                    safeTransfer(
                        tokenIn,
                        msg.sender, // V4_POOL_MANAGER
                        amountIn
                    );
                }
            } else if (!ethIn) {
                safeTransferFrom(
                    tokenIn,
                    payer,
                    msg.sender, // V4_POOL_MANAGER
                    amountIn
                );
            }

            uint256 amountOut = !exactOut ? takeAmount : swapAmount;
            if (amountLimit != 0 && (exactOut ? takeAmount > amountLimit : amountOut < amountLimit))
            {
                revert Slippage();
            }

            IV4PoolManager(msg.sender)
            .settle{value: ethIn ? (exactOut ? takeAmount : swapAmount) : 0}();
            IV4PoolManager(msg.sender).take(tokenOut, to, amountOut);

            result = abi.encode(amountIn, amountOut);

            if (ethIn) {
                if ((amountOut = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(payer, amountOut);
                }
            }
        }
    }

    function _swap(uint256 swapAmount, V4PoolKey memory key, bool zeroForOne, bool exactOut)
        internal
        returns (int256 delta)
    {
        unchecked {
            delta = IV4PoolManager(msg.sender)
                .swap(
                    key,
                    V4SwapParams(
                        zeroForOne,
                        exactOut ? int256(swapAmount) : -int256(swapAmount),
                        zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
                    ),
                    ""
                );
        }
    }

    /// @dev Pull in full and refund excess against zAMM.
    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        (address token0, address token1, bool zeroForOne) = _sortTokens(tokenIn, tokenOut);
        (uint256 id0, uint256 id1) = tokenIn == token0 ? (idIn, idOut) : (idOut, idIn);
        PoolKey memory key = PoolKey(id0, id1, token0, token1, feeOrHook);

        bool ethIn = tokenIn == address(0);
        if (!_useTransientBalance(
                address(this), tokenIn, idIn, !exactOut ? swapAmount : amountLimit
            )) {
            if (!ethIn) {
                if (idIn == 0) {
                    safeTransferFrom(
                        tokenIn, msg.sender, address(this), !exactOut ? swapAmount : amountLimit
                    );
                } else {
                    IERC6909(tokenIn)
                        .transferFrom(
                            msg.sender, address(this), idIn, !exactOut ? swapAmount : amountLimit
                        );
                }
            }
        }

        uint256 swapResult;
        if (!exactOut) {
            swapResult =
                IZAMM(ZAMM).swapExactIn(key, swapAmount, amountLimit, zeroForOne, to, deadline);
        } else {
            swapResult =
                IZAMM(ZAMM).swapExactOut(key, swapAmount, amountLimit, zeroForOne, to, deadline);
        }

        // ── return values ────────────────────────────────
        (amountIn, amountOut) = exactOut ? (swapResult, swapAmount) : (swapAmount, swapResult);

        if (exactOut && to != address(this)) {
            uint256 refund = ethIn ? address(this).balance : balanceOf(tokenIn);
            if (refund != 0) {
                if (ethIn) _safeTransferETH(msg.sender, refund);
                else safeTransfer(tokenIn, msg.sender, refund);
            }
        } else {
            depositFor(tokenOut, idOut, amountOut, to); // marks output target
        }
    }

    /// @dev To be called following deposit() or other swaps in sequence.
    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) public payable returns (uint256 amount0, uint256 amount1, uint256 liquidity) {
        bool ethIn = (poolKey.token0 == address(0));
        (amount0, amount1, liquidity) = IZAMM(ZAMM).addLiquidity{value: ethIn ? amount0Desired : 0}(
            poolKey, amount0Desired, amount1Desired, amount0Min, amount1Min, to, deadline
        );
    }

    /// @dev Allows remote pulls by zAMM for swapZAMM() calls.
    function ensureAllowance(address token, bool is6909) public payable {
        if (is6909) {
            IERC6909(token).setOperator(ZAMM, true);
        } else {
            safeApprove(token, ZAMM, type(uint256).max);
            safeApprove(token, V4_ROUTER, type(uint256).max);
        }
    }

    // ** AERO SWAPS

    function swapAero(
        address to,
        bool stable,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);
        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _aeroPoolFor(tokenIn, tokenOut, stable);

        amountIn = swapAmount;
        amountOut = IAeroPool(pool).getAmountOut(amountIn, tokenIn);
        require(amountLimit == 0 || amountOut >= amountLimit, Slippage());

        if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                safeTransfer(tokenIn, pool, amountIn);
            } else if (ethIn) {
                wrapETH(pool, amountIn);
                if (to != address(this) && msg.value > amountIn) {
                    _safeTransferETH(msg.sender, msg.value - amountIn);
                }
            } else {
                safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
            }
        }

        // Execute swap (Aerodrome is V2-like: push first, then swap):
        if (zeroForOne) {
            IAeroPool(pool).swap(0, amountOut, ethOut ? address(this) : to, "");
        } else {
            IAeroPool(pool).swap(amountOut, 0, ethOut ? address(this) : to, "");
        }

        if (ethOut) {
            unwrapETH(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            depositFor(tokenOut, 0, amountOut, to); // marks output target
        }
    }

    function swapAeroCL(
        address to,
        bool exactOut,
        int24 tickSpacing,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WETH;
        if (ethOut) tokenOut = WETH;

        (address pool, bool zeroForOne) = _aeroCLPoolFor(tokenIn, tokenOut, tickSpacing);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

        unchecked {
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(
                        ethIn, ethOut, true, msg.sender, tokenIn, tokenOut, to, tickSpacing
                    )
                );

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // ── return values ────────────────────────────────
            // ── translate pool deltas to user-facing amounts ─
            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);

            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            } else if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to); // marks output target
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        public
        payable
    {
        unchecked {
            bool ethIn;
            bool ethOut;
            bool isAero;
            address payer;
            address tokenIn;
            address tokenOut;
            address to;
            int24 tickSpacing;
            assembly ("memory-safe") {
                ethIn := byte(0, calldataload(0x84))
                ethOut := byte(0, calldataload(add(0x84, 1)))
                isAero := byte(0, calldataload(add(0x84, 2)))
                payer := shr(96, calldataload(add(0x84, 3)))
                tokenIn := shr(96, calldataload(add(0x84, 23)))
                tokenOut := shr(96, calldataload(add(0x84, 43)))
                to := shr(96, calldataload(add(0x84, 63)))
                tickSpacing := and(shr(232, calldataload(add(0x84, 83))), 0xFFFFFF)
            }
            require(amount0Delta != 0 || amount1Delta != 0, BadSwap());
            (address pool, bool zeroForOne) = isAero
                ? _aeroCLPoolFor(tokenIn, tokenOut, tickSpacing)
                : _v3PoolFor(tokenIn, tokenOut, uint24(tickSpacing));
            require(msg.sender == pool, Unauthorized());
            uint256 amountRequired = uint256(zeroForOne ? amount0Delta : amount1Delta);

            if (_useTransientBalance(address(this), tokenIn, 0, amountRequired)) {
                safeTransfer(tokenIn, pool, amountRequired);
            } else if (ethIn) {
                wrapETH(pool, amountRequired);
            } else {
                safeTransferFrom(tokenIn, payer, pool, amountRequired);
            }
            if (ethOut) {
                uint256 amountOut = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
                unwrapETH(amountOut);
                _safeTransferETH(to, amountOut);
            }
        }
    }

    // ** MULITSWAP HELPER

    function multicall(bytes[] calldata data) public payable returns (bytes[] memory) {
        assembly ("memory-safe") {
            mstore(0x00, 0x20)
            mstore(0x20, data.length)
            if iszero(data.length) { return(0x00, 0x40) }
            let results := 0x40
            let end := shl(5, data.length)
            calldatacopy(0x40, data.offset, end)
            let resultsOffset := end
            end := add(results, end)
            for {} 1 {} {
                let o := add(data.offset, mload(results))
                let m := add(resultsOffset, 0x40)
                calldatacopy(m, add(o, 0x20), calldataload(o))
                if iszero(delegatecall(gas(), address(), m, calldataload(o), codesize(), 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
                mstore(results, resultsOffset)
                results := add(results, 0x20)
                mstore(m, returndatasize())
                returndatacopy(add(m, 0x20), 0x00, returndatasize())
                resultsOffset := and(
                    add(add(resultsOffset, returndatasize()), 0x3f),
                    0xffffffffffffffe0
                )
                if iszero(lt(results, end)) { break }
            }
            return(0x00, add(resultsOffset, 0x40))
        }
    }

    // ** TRANSIENT STORAGE

    function deposit(address token, uint256 id, uint256 amount) public payable {
        if (msg.value != 0) {
            require(id == 0, InvalidId());
            if (token == WETH) {
                require(msg.value == amount, InvalidMsgVal());
                _safeTransferETH(WETH, amount); // wrap to WETH
            } else {
                require(msg.value == (token == address(0) ? amount : 0), InvalidMsgVal());
            }
        }
        if (token != address(0) && msg.value == 0) {
            if (id == 0) safeTransferFrom(token, msg.sender, address(this), amount);
            else IERC6909(token).transferFrom(msg.sender, address(this), id, amount);
        }
        depositFor(token, id, amount, address(this)); // transient storage tracker
    }

    function _useTransientBalance(address user, address token, uint256 id, uint256 amount)
        internal
        returns (bool credited)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x00, user)
            mstore(0x20, token)
            mstore(0x40, id)
            let slot := keccak256(0x00, 0x60)
            let bal := tload(slot)
            if iszero(lt(bal, amount)) {
                tstore(slot, sub(bal, amount))
                credited := 1
            }
            mstore(0x40, m)
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (to == address(this)) {
            depositFor(address(0), 0, amount, to);
            return;
        }
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb)
                revert(0x1c, 0x04)
            }
        }
    }

    // ** RECEIVER & SWEEPER

    receive() external payable {}

    function sweep(address token, uint256 id, uint256 amount, address to) public payable {
        if (token == address(0)) {
            _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
        } else if (id == 0) {
            safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
        } else {
            IERC6909(token)
                .transfer(
                    to, id, amount == 0 ? IERC6909(token).balanceOf(address(this), id) : amount
                );
        }
    }

    // ** WETH HELPERS

    function wrap(uint256 amount) public payable {
        amount = amount == 0 ? address(this).balance : amount;
        _safeTransferETH(WETH, amount);
        depositFor(WETH, 0, amount, address(this));
    }

    function unwrap(uint256 amount) public payable {
        unwrapETH(amount == 0 ? balanceOf(WETH) : amount);
    }

    // ** POOL HELPERS

    function _v2PoolFor(address tokenA, address tokenB)
        internal
        pure
        returns (address v2pool, bool zeroForOne)
    {
        unchecked {
            (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
            zeroForOne = zF1;
            v2pool = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                V2_FACTORY,
                                keccak256(abi.encodePacked(token0, token1)),
                                V2_POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
        }
    }

    function _v3PoolFor(address tokenA, address tokenB, uint24 fee)
        internal
        pure
        returns (address v3pool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        v3pool = _computeV3pool(token0, token1, fee);
    }

    function _computeV3pool(address token0, address token1, uint24 fee)
        internal
        pure
        returns (address v3pool)
    {
        bytes32 salt = _hash(token0, token1, fee);
        assembly ("memory-safe") {
            mstore8(0x00, 0xff)
            mstore(0x35, V3_POOL_INIT_CODE_HASH)
            mstore(0x01, shl(96, V3_FACTORY))
            mstore(0x15, salt)
            v3pool := keccak256(0x00, 0x55)
            mstore(0x35, 0)
        }
    }

    function _hash(address value0, address value1, uint24 value2)
        internal
        pure
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, value0)
            mstore(add(m, 0x20), value1)
            mstore(add(m, 0x40), value2)
            result := keccak256(m, 0x60)
        }
    }

    function _aeroPoolFor(address tokenA, address tokenB, bool stable)
        internal
        pure
        returns (address aeroPool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), AERO_FACTORY)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), AERO_IMPLEMENTATION)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            aeroPool := keccak256(add(ptr, 0x43), 0x55)
        }
    }

    function _aeroCLPoolFor(address tokenA, address tokenB, int24 tickSpacing)
        internal
        pure
        returns (address aeroCLPool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        bytes32 salt = keccak256(abi.encode(token0, token1, tickSpacing));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, AERO_CL_IMPLEMENTATION))
            mstore(
                add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf3ff00000000000000000000000000000000
            )
            mstore(add(ptr, 0x38), shl(0x60, AERO_CL_FACTORY))
            mstore(add(ptr, 0x4c), salt)
            mstore(add(ptr, 0x6c), keccak256(ptr, 0x37))
            aeroCLPool := keccak256(add(ptr, 0x37), 0x55)
        }
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // FALLBACK CALLDATA COMPRESSION:
    // Solady (https://github.com/Vectorized/solady/blob/main/src/utils/LibZip.sol)
    fallback() external payable {
        assembly ("memory-safe") {
            if iszero(calldatasize()) { return(calldatasize(), calldatasize()) }
            let o := 0
            let f := not(3)
            for { let i := 0 } lt(i, calldatasize()) {} {
                let c := byte(0, xor(add(i, f), calldataload(i)))
                i := add(i, 1)
                if iszero(c) {
                    let d := byte(0, xor(add(i, f), calldataload(i)))
                    i := add(i, 1)
                    mstore(o, not(0))
                    if iszero(gt(d, 0x7f)) { calldatacopy(o, calldatasize(), add(d, 1)) }
                    o := add(o, add(and(d, 0x7f), 1))
                    continue
                }
                mstore8(o, c)
                o := add(o, 1)
            }
            let success := delegatecall(gas(), address(), 0x00, o, codesize(), 0x00)
            returndatacopy(0x00, 0x00, returndatasize())
            if iszero(success) { revert(0x00, returndatasize()) }
            return(0x00, returndatasize())
        }
    }
}

// Uniswap helpers:

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

interface IV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

address constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
bytes32 constant V3_POOL_INIT_CODE_HASH =
    0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

address constant V4_ROUTER = 0x00000000000044a361Ae3cAc094c9D1b14Eece97;
address constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

interface IV4Router {
    function swap(bytes calldata data, uint256 deadline) external payable returns (int256);
}

struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

using BalanceDeltaLibrary for int256;

library BalanceDeltaLibrary {
    function amount0(int256 balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            _amount0 := sar(128, balanceDelta)
        }
    }

    function amount1(int256 balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            _amount1 := signextend(15, balanceDelta)
        }
    }
}

// zAMM helpers:

address constant ZAMM = 0x000000000000040470635EB91b7CE4D132D616eD;

struct PoolKey {
    uint256 id0;
    uint256 id1;
    address token0;
    address token1;
    uint256 feeOrHook;
}

interface IZAMM {
    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    function swapExactOut(
        PoolKey calldata poolKey,
        uint256 amountOut,
        uint256 amountInMax,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
}

// ** Aerodrome:

address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_IMPLEMENTATION = 0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7;

interface IAeroPool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
}

address constant AERO_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
address constant AERO_CL_IMPLEMENTATION = 0xeC8E5342B19977B4eF8892e02D8DAEcfa1315831;

// Solady safe transfer helpers:

error TransferFailed();

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

error TransferFromFailed();

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

error ApproveFailed();

function safeApprove(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0x095ea7b3000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x3e3f8f73)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}

// ** ERC6909

interface IERC6909 {
    function setOperator(address spender, bool approved) external returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
}

// Low-level WETH helpers - we know WETH so we can make assumptions:

address constant WETH = 0x4200000000000000000000000000000000000006;

function wrapETH(address pool, uint256 amount) {
    assembly ("memory-safe") {
        pop(call(gas(), WETH, amount, codesize(), 0x00, codesize(), 0x00))
        mstore(0x14, pool)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        pop(call(gas(), WETH, 0, 0x10, 0x44, codesize(), 0x00))
        mstore(0x34, 0)
    }
}

function unwrapETH(uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x00, 0x2e1a7d4d)
        mstore(0x20, amount)
        pop(call(gas(), WETH, 0, 0x1c, 0x24, codesize(), 0x00))
    }
}

// ** TRANSIENT DEPOSIT

function depositFor(address token, uint256 id, uint256 amount, address _for) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x00, _for)
        mstore(0x20, token)
        mstore(0x40, id)
        let slot := keccak256(0x00, 0x60)
        tstore(slot, add(tload(slot), amount))
        mstore(0x40, m)
    }
}
