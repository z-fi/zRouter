// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @dev uniV2 / uniV3 / uniV4 / zaps
///      multi-amm multi-call router
///      optimized with simple abi.
contract zRouter {
    error BadSwap();
    error Expired();
    error Slippage();
    error InvalidId();
    error Unauthorized();
    error InvalidMsgVal();
    error ETHTransferFailed();
    error SnwapSlippage(address token, uint256 received, uint256 minimum);

    SafeExecutor public immutable safeExecutor;

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, Expired());
        _;
    }

    event OwnershipTransferred(address indexed from, address indexed to);

    constructor() payable {
        safeExecutor = new SafeExecutor();
        emit OwnershipTransferred(address(0), _owner = tx.origin);
    }

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
                if (swapAmount == 0) {
                    amountIn = ethIn ? msg.value : balanceOf(tokenIn);
                    if (amountIn == 0) revert BadSwap();
                } else {
                    amountIn = swapAmount;
                }
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
            if (!exactOut && swapAmount == 0) {
                swapAmount = ethIn ? msg.value : balanceOf(tokenIn);
                if (swapAmount == 0) revert BadSwap();
            }
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(ethIn, ethOut, msg.sender, tokenIn, tokenOut, to, swapFee)
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

            // Handle ETH input refund (separate from output tracking)
            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            }
            // Handle output tracking for chaining (must always run when !ethOut)
            if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to);
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`.
    fallback() external payable {
        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }
        unchecked {
            int256 amount0Delta;
            int256 amount1Delta;
            bool ethIn;
            bool ethOut;
            address payer;
            address tokenIn;
            address tokenOut;
            address to;
            uint24 swapFee;
            assembly ("memory-safe") {
                amount0Delta := calldataload(0x4)
                amount1Delta := calldataload(0x24)
                ethIn := byte(0, calldataload(0x84))
                ethOut := byte(0, calldataload(add(0x84, 1)))
                payer := shr(96, calldataload(add(0x84, 2)))
                tokenIn := shr(96, calldataload(add(0x84, 22)))
                tokenOut := shr(96, calldataload(add(0x84, 42)))
                to := shr(96, calldataload(add(0x84, 62)))
                swapFee := and(shr(232, calldataload(add(0x84, 82))), 0xFFFFFF)
            }
            require(amount0Delta != 0 || amount1Delta != 0, BadSwap());
            (address pool, bool zeroForOne) = _v3PoolFor(tokenIn, tokenOut, swapFee);
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
        if (!exactOut && swapAmount == 0) {
            swapAmount = tokenIn == address(0) ? msg.value : balanceOf(tokenIn);
            if (swapAmount == 0) revert BadSwap();
        }
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

    /// @dev Handle V4 PoolManager swap callback - hookless default.
    function unlockCallback(bytes calldata callbackData)
        public
        payable
        returns (bytes memory result)
    {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }

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
                uint256 ethRefund = address(this).balance;
                if (ethRefund != 0 && to != address(this)) {
                    _safeTransferETH(payer, ethRefund);
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

    function ensureAllowance(address token, bool is6909, address to) public payable onlyOwner {
        if (is6909) IERC6909(token).setOperator(to, true);
        else safeApprove(token, to, type(uint256).max);
    }

    // ** PERMIT HELPERS

    function permit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        payable
    {
        IERC2612(token).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    function permit2TransferFrom(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public payable {
        IPermit2(PERMIT2)
            .permitTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({token: token, amount: amount}),
                    nonce: nonce,
                    deadline: deadline
                }),
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
                msg.sender,
                signature
            );
        depositFor(token, 0, amount, address(this));
    }

    function permit2BatchTransferFrom(
        IPermit2.TokenPermissions[] calldata permitted,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public payable {
        uint256 len = permitted.length;
        IPermit2.SignatureTransferDetails[] memory details =
            new IPermit2.SignatureTransferDetails[](len);

        for (uint256 i; i != len; ++i) {
            details[i] = IPermit2.SignatureTransferDetails({
                to: address(this), requestedAmount: permitted[i].amount
            });
        }

        IPermit2(PERMIT2)
            .permitBatchTransferFrom(
                IPermit2.PermitBatchTransferFrom({
                    permitted: permitted, nonce: nonce, deadline: deadline
                }),
                details,
                msg.sender,
                signature
            );

        for (uint256 i; i != len; ++i) {
            depositFor(permitted[i].token, 0, permitted[i].amount, address(this));
        }
    }

    // ** MULTISWAP HELPER

    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
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

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // EXECUTE EXTENSIONS

    address _owner;

    modifier onlyOwner() {
        require(msg.sender == _owner, Unauthorized());
        _;
    }

    mapping(address target => bool) _isTrustedForCall;

    function trust(address target, bool ok) public payable onlyOwner {
        _isTrustedForCall[target] = ok;
    }

    function transferOwnership(address owner) public payable onlyOwner {
        emit OwnershipTransferred(msg.sender, _owner = owner);
    }

    function execute(address target, uint256 value, bytes calldata data)
        public
        payable
        returns (bytes memory result)
    {
        require(_isTrustedForCall[target], Unauthorized());
        assembly ("memory-safe") {
            tstore(0x00, 1) // lock callback (V3/V4)
            result := mload(0x40)
            calldatacopy(result, data.offset, data.length)
            if iszero(call(gas(), target, value, result, data.length, codesize(), 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            mstore(result, returndatasize())
            let o := add(result, 0x20)
            returndatacopy(o, 0x00, returndatasize())
            mstore(0x40, add(o, returndatasize()))
            tstore(0x00, 0) // unlock callback
        }
    }

    // SNWAP - GENERIC EXECUTOR ****

    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256 amountOut) {
        uint256 initialBalance = tokenOut == address(0)
            ? recipient.balance
            : balanceOfAccount(tokenOut, recipient);

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        uint256 finalBalance =
            tokenOut == address(0) ? recipient.balance : balanceOfAccount(tokenOut, recipient);
        amountOut = finalBalance - initialBalance;
        if (amountOut < amountOutMin) revert SnwapSlippage(tokenOut, amountOut, amountOutMin);
        if (recipient == address(this)) depositFor(tokenOut, 0, amountOut, address(this));
    }

    function snwapMulti(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address[] calldata tokensOut,
        uint256[] calldata amountsOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256[] memory amountsOut) {
        uint256 len = tokensOut.length;
        uint256[] memory initBals = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            initBals[i] = tokensOut[i] == address(0)
                ? recipient.balance
                : balanceOfAccount(tokensOut[i], recipient);
        }

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        amountsOut = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            uint256 finalBal = tokensOut[i] == address(0)
                ? recipient.balance
                : balanceOfAccount(tokensOut[i], recipient);
            amountsOut[i] = finalBal - initBals[i];
            if (amountsOut[i] < amountsOutMin[i]) {
                revert SnwapSlippage(tokensOut[i], amountsOut[i], amountsOutMin[i]);
            }
            if (recipient == address(this)) {
                depositFor(tokensOut[i], 0, amountsOut[i], address(this));
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        public
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

// Uniswap helpers:

address constant V2_FACTORY = 0x0c3c1c532F1e39EdF36BE9Fe0bE1410313E074Bf;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

interface IV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

address constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
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

address constant V4_POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;

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

function balanceOfAccount(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
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

// ** PERMIT HELPERS

address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

interface IERC2612 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function permitBatchTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// ** SNWAP HELPERS

// modified from 0xAC4c6e212A361c968F1725b4d055b47E63F80b75 - sushi yum

/// @dev SafeExecutor - has no token approvals, safe for arbitrary external calls
contract SafeExecutor {
    function execute(address target, bytes calldata data) public payable {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), target, callvalue(), m, data.length, codesize(), 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }
}
