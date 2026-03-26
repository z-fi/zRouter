// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title zQuoterLens
/// @notice A lean read-only wrapper that exposes the same getters as zQuoterBase
///         and forwards them to a deployed ZQUOTER_BASE. Return data unchanged.
contract zQuoterLens {
    zQuoterLens public constant ZQUOTER_BASE =
        zQuoterLens(0xa8Cc0177598531eC7D223E9689fdD50E120b946c);

    enum AMM {
        UNI_V2,
        AERO,
        ZAMM,
        UNI_V3,
        UNI_V4,
        AERO_CL
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    constructor() payable {}

    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (Quote memory best, Quote[] memory quotes)
    {
        return ZQUOTER_BASE.getQuotes(exactOut, tokenIn, tokenOut, swapAmount);
    }

    function quoteV2(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        return ZQUOTER_BASE.quoteV2(exactOut, tokenIn, tokenOut, swapAmount);
    }

    function quoteV3(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteV3(exactOut, tokenIn, tokenOut, fee, swapAmount);
    }

    function quoteV4(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteV4(
            exactOut, tokenIn, tokenOut, fee, tickSpacing, hooks, swapAmount
        );
    }

    function quoteZAMM(
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteZAMM(
            exactOut, feeOrHook, tokenIn, tokenOut, idIn, idOut, swapAmount
        );
    }

    function quoteAero(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 feeBpsUsed)
    {
        return ZQUOTER_BASE.quoteAero(exactOut, tokenIn, tokenOut, swapAmount);
    }

    function quoteAeroCL(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        int24 spacing,
        uint256 swapAmount
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        return ZQUOTER_BASE.quoteAeroCL(exactOut, tokenIn, tokenOut, spacing, swapAmount);
    }

    function limit(bool exactOut, uint256 quoted, uint256 bps) public view returns (uint256) {
        return ZQUOTER_BASE.limit(exactOut, quoted, bps);
    }

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue)
    {
        return ZQUOTER_BASE.buildBestSwap(
            to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
        );
    }
}

/// @title zQuoter
/// @notice Efficient multicall builder
///         leveraging the base quoter.
contract zQuoter is zQuoterLens {
    error NoRoute();
    error ZeroAmount();
    error UnsupportedAMM();

    constructor() payable {}

    function _buildV2Swap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV2.selector,
            to,
            exactOut,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildZAMMSwap(
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
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapVZ.selector,
            to,
            exactOut,
            feeOrHook,
            tokenIn,
            tokenOut,
            idIn,
            idOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildV3Swap(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV3.selector,
            to,
            exactOut,
            swapFee,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildV4Swap(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapV4.selector,
            to,
            exactOut,
            swapFee,
            tickSpace,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    // ** BUILD AERO

    function _buildAeroSwap(
        address to,
        bool stable, // true = stable pool, false = volatile
        address tokenIn,
        address tokenOut,
        uint256 swapAmount, // ALWAYS input amount (exact-in call)
        uint256 amountLimit, // minOut (0 to skip)
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapAero.selector,
            to,
            stable,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _buildAeroCLSwap(
        address to,
        bool exactOut,
        int24 tickSpacing,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        callData = abi.encodeWithSelector(
            IZRouter.swapAeroCL.selector,
            to,
            exactOut,
            tickSpacing,
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            deadline
        );
    }

    function _spacingFromBps(uint16 bps) internal pure returns (int24) {
        unchecked {
            // legacy encodings
            if (bps == 1) return 1;
            if (bps == 5) return 10;
            if (bps == 30) return 60;
            if (bps == 100) return 200;
            // (factory currently enables 1, 50, 100, 200, 2000… but this stays generic)
            return int24(uint24(bps));
        }
    }

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut, // overall: false = exactIn, true = exactOut (on tokenOut)
        address tokenIn, // ERC20 or address(0) for ETH
        address tokenOut, // ERC20 or address(0) for ETH
        uint256 swapAmount, // exactIn: amount of tokenIn; exactOut: desired tokenOut
        uint256 slippageBps, // per-leg bound
        uint256 deadline
    )
        public
        view
        returns (
            Quote memory a,
            Quote memory b,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        )
    {
        unchecked {
            require(swapAmount != 0, ZeroAmount());

            uint256 n;
            uint256 k;

            // --- single hop if either side is native ETH (router abstracts WETH) ---
            if (
                tokenIn == address(0) || tokenOut == address(0) || tokenIn == WETH
                    || tokenOut == WETH
            ) {
                (Quote memory best, bytes memory callData,, uint256 val) = buildBestSwap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
                );

                // No sweeps; router won’t strand dust even if `to == ZROUTER`
                calls = new bytes[](1);
                calls[0] = callData;

                // return (a=best, b=empty):
                a = best;
                b = Quote(AMM.UNI_V2, 0, 0, 0);
                msgValue = val;

                multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);
                return (a, b, calls, multicall, msgValue);
            }

            // --- two-hop via WETH as middle ---
            address MID = WETH;

            uint256 leg1AmountLimit;
            uint256 leg2AmountLimit;
            uint256 midAmtForLeg2;

            if (!exactOut) {
                // overall exactIn:
                (a,) = getQuotes(false, tokenIn, MID, swapAmount);
                if (a.amountOut == 0) revert NoRoute();

                midAmtForLeg2 = SlippageLib.limit(false, a.amountOut, slippageBps); // min mid for hop-2
                leg1AmountLimit = midAmtForLeg2;

                (b,) = getQuotes(false, MID, tokenOut, midAmtForLeg2);
                if (b.amountOut == 0) revert NoRoute();
                leg2AmountLimit = SlippageLib.limit(false, b.amountOut, slippageBps);
            } else {
                // overall exactOut:
                (b,) = getQuotes(true, MID, tokenOut, swapAmount);
                if (b.amountIn == 0) revert NoRoute();
                uint256 midRequired = b.amountIn;
                uint256 midLimit = SlippageLib.limit(true, midRequired, slippageBps); // hop-2 maxIn
                leg2AmountLimit = midLimit;

                bool prefundV2 = (b.source == AMM.UNI_V2 || b.source == AMM.AERO);
                uint256 midToProduce = prefundV2 ? midRequired : midLimit;

                (a,) = getQuotes(true, tokenIn, MID, midToProduce);
                if (a.amountIn == 0) revert NoRoute();
                leg1AmountLimit = SlippageLib.limit(true, a.amountIn, slippageBps);
                midAmtForLeg2 = midToProduce;
            }

            // hop-1 recipient: pool-prefund only for V2/Aero in overall exactOut; otherwise router
            address leg1To = ZROUTER;
            if (exactOut && (b.source == AMM.UNI_V2 || b.source == AMM.AERO)) {
                address tOut = tokenOut;
                address pool;
                if (b.source == AMM.UNI_V2) {
                    (pool,) = _v2PoolFor(MID, tOut);
                } else {
                    bool stable = (b.feeBps <= 2);
                    (pool,) = _aeroPoolFor(MID, tOut, stable);
                }
                leg1To = pool; // push WETH to hop-2 pool; hop-2 consumes transient credit
            }

            // build hop-1:
            bytes memory legAData = _buildCallForQuote(
                a,
                leg1To,
                /*exactOut*/
                exactOut, // hop-1 exactness mirrors overall
                tokenIn,
                MID,
                /*swapAmount*/
                exactOut ? midAmtForLeg2 : swapAmount,
                leg1AmountLimit,
                deadline
            );

            // build hop-2:
            bytes memory legBData = _buildCallForQuote(
                b,
                to,
                /*exactOut*/
                exactOut,
                MID,
                tokenOut,
                /*swapAmount*/
                exactOut ? swapAmount : midAmtForLeg2,
                leg2AmountLimit,
                deadline
            );

            // safety sweeps (return router-held dust to refundTo)
            bool zamm2ExactOut = exactOut && (b.source == AMM.ZAMM);

            // Only need mid sweep when hop-1 lands mid at router and hop-2 isn't zAMM exact-out
            bool needWethSweep = (!zamm2ExactOut) && (leg1To == ZROUTER);

            // If hop-1 is zAMM exact-out to the router, zRouter pre-pulls up to amountLimit;
            // any leftover tokenIn would otherwise sit on the router
            bool needInSweep = (a.source == AMM.ZAMM) && exactOut && (leg1To == ZROUTER);

            // assemble calls
            n = 2 + (needWethSweep ? 2 : 0) + (needInSweep ? 1 : 0); // unwrap + sweep(ETH) if needed
            calls = new bytes[](n);
            k = 0;
            calls[k++] = legAData;
            calls[k++] = legBData;

            if (needWethSweep) {
                // unwrap all router-held WETH then sweep ETH to refundTo
                calls[k++] = abi.encodeWithSelector(IRouterExt.unwrap.selector, 0);
                calls[k++] =
                    abi.encodeWithSelector(IRouterExt.sweep.selector, address(0), 0, 0, refundTo);
            }
            if (needInSweep) {
                calls[k++] =
                    abi.encodeWithSelector(IRouterExt.sweep.selector, tokenIn, 0, 0, refundTo);
            }

            // Encoded calldata to send to ZROUTER (value = msgValue):
            multicall = abi.encodeWithSelector(IRouterExt.multicall.selector, calls);

            // msg.value only needed for hop-1 if tokenIn is native ETH (router rule):
            msgValue = _requiredMsgValue(
                /*exactOut*/
                exactOut,
                tokenIn,
                /*swapAmount*/
                exactOut ? midAmtForLeg2 : swapAmount,
                /*amountLimit*/
                leg1AmountLimit
            );
        }
    }

    /* msg.value rule (matches zRouter):
       tokenIn==ETH → exactIn: swapAmount, exactOut: amountLimit; else 0. */
    function _requiredMsgValue(
        bool exactOut,
        address tokenIn,
        uint256 swapAmount,
        uint256 amountLimit
    ) internal pure returns (uint256) {
        return tokenIn == address(0) ? (exactOut ? amountLimit : swapAmount) : 0;
    }

    /*──────────────── helpers ───────────────*/

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

    function _aeroPoolFor(address tokenA, address tokenB, bool stable)
        internal
        pure
        returns (address aeroPool, bool zeroForOne)
    {
        unchecked {
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
    }

    function _buildCallForQuote(
        Quote memory q,
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) internal pure returns (bytes memory callData) {
        unchecked {
            if (q.source == AMM.UNI_V2) {
                callData = _buildV2Swap(
                    to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline
                );
            } else if (q.source == AMM.AERO) {
                bool stable = (q.feeBps <= 2);
                callData = _buildAeroSwap(
                    to, stable, tokenIn, tokenOut, swapAmount, amountLimit, deadline
                );
            } else if (q.source == AMM.ZAMM) {
                callData = _buildZAMMSwap(
                    to,
                    exactOut,
                    q.feeBps,
                    tokenIn,
                    tokenOut,
                    0,
                    0,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (q.source == AMM.UNI_V3) {
                callData = _buildV3Swap(
                    to,
                    exactOut,
                    uint24(q.feeBps * 100),
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (q.source == AMM.UNI_V4) {
                int24 spacing = _spacingFromBps(uint16(q.feeBps));
                callData = _buildV4Swap(
                    to,
                    exactOut,
                    uint24(q.feeBps * 100),
                    spacing,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    deadline
                );
            } else if (q.source == AMM.AERO_CL) {
                int24 spacing = _spacingFromBps(uint16(q.feeBps));
                callData = _buildAeroCLSwap(
                    to, exactOut, spacing, tokenIn, tokenOut, swapAmount, amountLimit, deadline
                );
            } else {
                revert UnsupportedAMM();
            }
        }
    }

    // Calldata compression (Solady):

    function cdCompress(bytes memory data) public pure returns (bytes memory result) {
        assembly ("memory-safe") {
            function countLeadingZeroBytes(x_) -> _r {
                _r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x_))
                _r := or(_r, shl(6, lt(0xffffffffffffffff, shr(_r, x_))))
                _r := or(_r, shl(5, lt(0xffffffff, shr(_r, x_))))
                _r := or(_r, shl(4, lt(0xffff, shr(_r, x_))))
                _r := xor(31, or(shr(3, _r), lt(0xff, shr(_r, x_))))
            }
            function min(x_, y_) -> _z {
                _z := xor(x_, mul(xor(x_, y_), lt(y_, x_)))
            }
            result := mload(0x40)
            let end := add(data, mload(data))
            let m := 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f
            let o := add(result, 0x20)
            for { let i := data } iszero(eq(i, end)) {} {
                i := add(i, 1)
                let c := byte(31, mload(i))
                if iszero(c) {
                    for {} 1 {} {
                        let x := mload(add(i, 0x20))
                        if iszero(x) {
                            let r := min(sub(end, i), 0x20)
                            r := min(sub(0x7f, c), r)
                            i := add(i, r)
                            c := add(c, r)
                            if iszero(gt(r, 0x1f)) { break }
                            continue
                        }
                        let r := countLeadingZeroBytes(x)
                        r := min(sub(end, i), r)
                        i := add(i, r)
                        c := add(c, r)
                        break
                    }
                    mstore(o, shl(240, c))
                    o := add(o, 2)
                    continue
                }
                if eq(c, 0xff) {
                    let r := 0x20
                    let x := not(mload(add(i, r)))
                    if x { r := countLeadingZeroBytes(x) }
                    r := min(min(sub(end, i), r), 0x1f)
                    i := add(i, r)
                    mstore(o, shl(240, or(r, 0x80)))
                    o := add(o, 2)
                    continue
                }
                mstore8(o, c)
                o := add(o, 1)
                c := mload(add(i, 0x20))
                mstore(o, c)
                // `.each(b => b == 0x00 || b == 0xff ? 0x80 : 0x00)`.
                c := not(or(and(or(add(and(c, m), m), c), or(add(and(not(c), m), m), not(c))), m))
                let r := shl(7, lt(0x8421084210842108cc6318c6db6d54be, c)) // Save bytecode.
                r := or(shl(6, lt(0xffffffffffffffff, shr(r, c))), r)
                // forgefmt: disable-next-item
                r := add(iszero(c), shr(3, xor(byte(and(0x1f, shr(byte(24,
                    mul(0x02040810204081, shr(r, c))), 0x8421084210842108cc6318c6db6d54be)),
                    0xc0c8c8d0c8e8d0d8c8e8e0e8d0d8e0f0c8d0e8d0e0e0d8f0d0d0e0d8f8f8f8f8), r)))
                r := min(sub(end, i), r)
                o := add(o, r)
                i := add(i, r)
            }
            // Bitwise negate the first 4 bytes.
            mstore(add(result, 4), not(mload(add(result, 4))))
            mstore(result, sub(o, add(result, 0x20))) // Store the length.
            mstore(o, 0) // Zeroize the slot after the string.
            mstore(0x40, add(o, 0x20)) // Allocate the memory.
        }
    }

    function buildBestSwapCompressed(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        public
        view
        returns (
            Quote memory best,
            bytes memory callData,
            bytes memory callDataCompressed,
            uint256 amountLimit,
            uint256 msgValue
        )
    {
        (best, callData, amountLimit, msgValue) =
            ZQUOTER_BASE.buildBestSwap(
                to, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
            );
        callDataCompressed = cdCompress(callData);
    }

    function buildBestSwapViaETHMulticallCompressed(
        address to,
        address refundTo,
        bool exactOut, // overall: false = exactIn, true = exactOut (on tokenOut)
        address tokenIn, // ERC20 or address(0) for ETH
        address tokenOut, // ERC20 or address(0) for ETH
        uint256 swapAmount, // exactIn: amount of tokenIn; exactOut: desired tokenOut
        uint256 slippageBps, // per-leg bound
        uint256 deadline
    )
        public
        view
        returns (
            Quote memory a,
            Quote memory b,
            bytes[] memory calls,
            bytes memory multicall,
            bytes memory multicallCompressed,
            uint256 msgValue
        )
    {
        (a, b, calls, multicall, msgValue) = buildBestSwapViaETHMulticall(
            to, refundTo, exactOut, tokenIn, tokenOut, swapAmount, slippageBps, deadline
        );
        multicallCompressed = cdCompress(multicall);
    }
}

address constant ZROUTER = 0x0000000000404FECAf36E6184245475eE1254835;

interface IRouterExt {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function sweep(address token, uint256 id, uint256 amount, address to) external payable;
    function unwrap(uint256 amount) external payable; // <-- add this
}

interface IZRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

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
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

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
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapAero(
        address to,
        bool stable,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);

    function swapAeroCL(
        address to,
        bool exactOut,
        int24 tickSpacing,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

address constant WETH = 0x4200000000000000000000000000000000000006;

address constant V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

address constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
address constant AERO_IMPLEMENTATION = 0xA4e46b4f701c62e14DF11B48dCe76A7d793CD6d7;

function _sortTokens(address tokenA, address tokenB)
    pure
    returns (address token0, address token1, bool zeroForOne)
{
    (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
}

library SlippageLib {
    uint256 constant BPS = 10_000;

    function limit(bool exactOut, uint256 quoted, uint256 bps) internal pure returns (uint256) {
        unchecked {
            if (exactOut) {
                // maxIn = ceil(quotedIn * (1 + bps/BPS))
                return (quoted * (BPS + bps) + BPS - 1) / BPS;
            } else {
                // minOut = floor(quotedOut * (1 - bps/BPS))
                return (quoted * (BPS - bps)) / BPS;
            }
        }
    }
}
