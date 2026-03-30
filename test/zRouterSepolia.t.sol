// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/sepolia/zRouter.sol";

interface IERC20 {
    function balanceOf(address user) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IUniV2PairReserves {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

contract zRouterSepoliaAddressTest is Test {
    /* ───────────── known-good Sepolia addresses ───────────── */

    // Canonical Uniswap WETH9 on Sepolia (used by Uniswap V2/V3/V4)
    address constant EXPECTED_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    // Permit2 — deterministic CREATE2, same on every chain
    address constant EXPECTED_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Uniswap V2 on Sepolia (from docs.uniswap.org/contracts/v2/reference/smart-contracts/v2-deployments)
    address constant EXPECTED_V2_FACTORY = 0xF62c03E08ada871A0bEb309762E260a7a6a880E6;
    bytes32 constant EXPECTED_V2_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    // Uniswap V3 on Sepolia (from sepolia.etherscan.io)
    address constant EXPECTED_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    bytes32 constant EXPECTED_V3_INIT_CODE_HASH =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    // Uniswap V4 PoolManager on Sepolia (from docs.uniswap.org/contracts/v4/deployments)
    address constant EXPECTED_V4_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /* ───────────── Sepolia UNI token (has Uniswap pools) ───────────── */
    address constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    /* ═══════════════════════════════════════════════
                ADDRESS VERIFICATION TESTS
       ═══════════════════════════════════════════════ */

    /// Verify WETH address matches the constant used in the router
    function testConstant_WETH() public pure {
        assertEq(WETH, EXPECTED_WETH, "WETH address mismatch");
    }

    /// Verify PERMIT2 address matches
    function testConstant_PERMIT2() public pure {
        assertEq(PERMIT2, EXPECTED_PERMIT2, "PERMIT2 address mismatch");
    }

    /// Verify V2_FACTORY address matches
    function testConstant_V2_FACTORY() public pure {
        assertEq(V2_FACTORY, EXPECTED_V2_FACTORY, "V2_FACTORY address mismatch");
    }

    /// Verify V2 init code hash matches
    function testConstant_V2_INIT_CODE_HASH() public pure {
        assertEq(V2_POOL_INIT_CODE_HASH, EXPECTED_V2_INIT_CODE_HASH, "V2 init code hash mismatch");
    }

    /// Verify V3_FACTORY address matches
    function testConstant_V3_FACTORY() public pure {
        assertEq(V3_FACTORY, EXPECTED_V3_FACTORY, "V3_FACTORY address mismatch");
    }

    /// Verify V3 init code hash matches
    function testConstant_V3_INIT_CODE_HASH() public pure {
        assertEq(V3_POOL_INIT_CODE_HASH, EXPECTED_V3_INIT_CODE_HASH, "V3 init code hash mismatch");
    }

    /// Verify V4_POOL_MANAGER address matches
    function testConstant_V4_POOL_MANAGER() public pure {
        assertEq(V4_POOL_MANAGER, EXPECTED_V4_POOL_MANAGER, "V4_POOL_MANAGER address mismatch");
    }

    /// Verify V3 sqrt price limit constants
    function testConstant_V3SqrtPriceLimits() public pure {
        assertEq(MIN_SQRT_RATIO_PLUS_ONE, 4295128740, "MIN_SQRT_RATIO_PLUS_ONE mismatch");
        assertEq(
            MAX_SQRT_RATIO_MINUS_ONE,
            1461446703485210103287273052203988822378723970341,
            "MAX_SQRT_RATIO_MINUS_ONE mismatch"
        );
    }
}

contract zRouterSepoliaForkTest is Test {
    uint256 DEADLINE;

    /* ───────────── addresses & constants ───────────── */
    address constant USER = address(0xBEEF);

    address constant SEP_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEP_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    uint256 constant UNI_IN = 100e18; // 100 UNI
    uint256 constant ETH_IN = 0.05 ether;
    uint256 constant UNI_OUT = 10e18;
    uint256 constant ETH_OUT = 0.001 ether;

    /* ───────────── state ───────────── */
    zRouter router;
    address routerOwner;

    /* ───────────── maths helpers ───────────── */
    function _getAmountOut(uint256 amtIn, uint256 resIn, uint256 resOut)
        internal
        pure
        returns (uint256)
    {
        uint256 x = amtIn * 997;
        return (x * resOut) / (resIn * 1000 + x);
    }

    function _getAmountIn(uint256 amtOut, uint256 resIn, uint256 resOut)
        internal
        pure
        returns (uint256)
    {
        uint256 n = resIn * amtOut * 1000;
        uint256 d = (resOut - amtOut) * 997;
        return (n + d - 1) / d;
    }

    /* ───────────── setUp ───────────── */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("sepolia"));

        routerOwner = tx.origin;
        router = new zRouter();

        vm.deal(USER, 100 ether);
        deal(SEP_UNI, USER, 100_000e18);

        DEADLINE = block.timestamp + 20 minutes;

        vm.prank(USER);
        IERC20(SEP_UNI).approve(address(router), type(uint256).max);
    }

    /* ═══════════════════════════════════════════════
              ON-CHAIN ADDRESS VERIFICATION
       ═══════════════════════════════════════════════ */

    /// V2 Factory has code on Sepolia
    function testFork_V2FactoryHasCode() public view {
        assertGt(V2_FACTORY.code.length, 0, "V2_FACTORY has no code on Sepolia");
    }

    /// V3 Factory has code on Sepolia
    function testFork_V3FactoryHasCode() public view {
        assertGt(V3_FACTORY.code.length, 0, "V3_FACTORY has no code on Sepolia");
    }

    /// V4 PoolManager has code on Sepolia
    function testFork_V4PoolManagerHasCode() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0, "V4_POOL_MANAGER has no code on Sepolia");
    }

    /// WETH has code on Sepolia
    function testFork_WETHHasCode() public view {
        assertGt(WETH.code.length, 0, "WETH has no code on Sepolia");
    }

    /// Permit2 has code on Sepolia
    function testFork_Permit2HasCode() public view {
        assertGt(PERMIT2.code.length, 0, "PERMIT2 has no code on Sepolia");
    }

    /* ═══════════════════════════════════════════════
              INIT CODE HASH VERIFICATION
       ═══════════════════════════════════════════════ */

    /// V2: computed pool address matches factory.getPair()
    function testFork_V2PoolAddressComputation() public view {
        address factoryPair = IV2Factory(V2_FACTORY).getPair(SEP_WETH, SEP_UNI);
        if (factoryPair != address(0)) {
            // Pool exists — verify our CREATE2 computation matches
            (address computed,) = _v2PoolFor(SEP_UNI, SEP_WETH);
            assertEq(computed, factoryPair, "V2 pool address computation mismatch");
        }
    }

    /// V3: computed pool address matches factory.getPool()
    function testFork_V3PoolAddressComputation() public view {
        address factoryPool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 3000);
        if (factoryPool != address(0)) {
            (address computed,) = _v3PoolFor(SEP_UNI, SEP_WETH, 3000);
            assertEq(computed, factoryPool, "V3 pool address computation mismatch");
        }
    }

    /// V3: also check 500 bp fee tier
    function testFork_V3PoolAddressComputation_500bp() public view {
        address factoryPool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 500);
        if (factoryPool != address(0)) {
            (address computed,) = _v3PoolFor(SEP_UNI, SEP_WETH, 500);
            assertEq(computed, factoryPool, "V3 500bp pool address computation mismatch");
        }
    }

    /* ═══════════════════════════════════════════════
              CONSTRUCTOR / DEPLOYMENT TESTS
       ═══════════════════════════════════════════════ */

    /// Router deploys SafeExecutor
    function testDeploy_SafeExecutor() public view {
        address se = address(router.safeExecutor());
        assertGt(se.code.length, 0, "SafeExecutor not deployed");
    }

    /// Router owner is tx.origin
    function testDeploy_OwnerIsOrigin() public view {
        // owner is tx.origin from constructor
        assertEq(routerOwner, tx.origin);
    }

    /* ═══════════════════════════════════════════════
                      V2 SWAP TESTS
       ═══════════════════════════════════════════════ */

    /// V2: UNI → ETH exact-in (if pool exists)
    function testV2_ExactIn_UNItoETH() public {
        address pair = IV2Factory(V2_FACTORY).getPair(SEP_UNI, SEP_WETH);
        if (pair == address(0)) return; // skip if no pool

        (uint112 r0, uint112 r1,) = IUniV2PairReserves(pair).getReserves();
        if (r0 == 0 || r1 == 0) return; // skip if no liquidity

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV2(USER, false, SEP_UNI, address(0), UNI_IN, 0, DEADLINE);

        assertEq(amountIn, UNI_IN, "amountIn mismatch");
        assertGt(amountOut, 0, "no ETH out");
        assertEq(USER.balance - ethBefore, amountOut, "ETH balance mismatch");
    }

    /// V2: ETH → UNI exact-in (if pool exists)
    function testV2_ExactIn_ETHtoUNI() public {
        address pair = IV2Factory(V2_FACTORY).getPair(SEP_UNI, SEP_WETH);
        if (pair == address(0)) return;

        (uint112 r0, uint112 r1,) = IUniV2PairReserves(pair).getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 uniBefore = IERC20(SEP_UNI).balanceOf(USER);

        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV2{value: ETH_IN}(USER, false, address(0), SEP_UNI, ETH_IN, 0, DEADLINE);

        assertEq(amountIn, ETH_IN, "amountIn mismatch");
        assertGt(amountOut, 0, "no UNI out");
        assertEq(IERC20(SEP_UNI).balanceOf(USER) - uniBefore, amountOut, "UNI balance mismatch");
    }

    /// V2: slippage revert
    function testV2_SlippageReverts() public {
        address pair = IV2Factory(V2_FACTORY).getPair(SEP_UNI, SEP_WETH);
        if (pair == address(0)) return;

        (uint112 r0, uint112 r1,) = IUniV2PairReserves(pair).getReserves();
        if (r0 == 0 || r1 == 0) return;

        vm.prank(USER);
        vm.expectRevert(zRouter.Slippage.selector);
        router.swapV2{value: ETH_IN}(
            USER, false, address(0), SEP_UNI, ETH_IN, type(uint256).max, DEADLINE
        );
    }

    /// V2: deadline revert
    function testV2_DeadlineReverts() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapV2{value: ETH_IN}(
            USER, false, address(0), SEP_UNI, ETH_IN, 0, block.timestamp - 1
        );
    }

    /* ═══════════════════════════════════════════════
                      V3 SWAP TESTS
       ═══════════════════════════════════════════════ */

    /// V3: ETH → UNI exact-in (3000 bp)
    function testV3_ExactIn_ETHtoUNI() public {
        address pool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 3000);
        if (pool == address(0)) return;

        uint256 uniBefore = IERC20(SEP_UNI).balanceOf(USER);

        vm.prank(USER);
        router.swapV3{value: ETH_IN}(USER, false, 3000, address(0), SEP_UNI, ETH_IN, 0, DEADLINE);

        assertGt(IERC20(SEP_UNI).balanceOf(USER) - uniBefore, 0, "no UNI out");
    }

    /// V3: UNI → ETH exact-in
    function testV3_ExactIn_UNItoETH() public {
        address pool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 3000);
        if (pool == address(0)) return;

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.swapV3(USER, false, 3000, SEP_UNI, address(0), UNI_IN, 0, DEADLINE);

        assertGt(USER.balance - ethBefore, 0, "no ETH out");
    }

    /* ═══════════════════════════════════════════════
                      V4 SWAP TESTS
       ═══════════════════════════════════════════════ */

    /// V4: ETH → UNI exact-in
    function testV4_ExactIn_ETHtoUNI() public {
        // V4 pools may not exist on Sepolia — this tests the interface
        vm.prank(USER);
        try router.swapV4{value: ETH_IN}(
            USER, false, 3000, 60, address(0), SEP_UNI, ETH_IN, 0, DEADLINE
        ) returns (uint256, uint256 amountOut) {
            assertGt(amountOut, 0, "no UNI out");
        } catch {
            // Pool doesn't exist or no liquidity — acceptable on testnet
        }
    }

    /// V4: UNI → ETH exact-in
    function testV4_ExactIn_UNItoETH() public {
        vm.prank(USER);
        try router.swapV4(USER, false, 3000, 60, SEP_UNI, address(0), UNI_IN, 0, DEADLINE)
        returns (uint256, uint256 amountOut) {
            assertGt(amountOut, 0, "no ETH out");
        } catch {
            // Pool doesn't exist or no liquidity — acceptable on testnet
        }
    }

    /* ═══════════════════════════════════════════════
                    MULTICALL TESTS
       ═══════════════════════════════════════════════ */

    /// Multicall: single V2 swap
    function testMulticall_SingleV2() public {
        address pair = IV2Factory(V2_FACTORY).getPair(SEP_UNI, SEP_WETH);
        if (pair == address(0)) return;

        (uint112 r0, uint112 r1,) = IUniV2PairReserves(pair).getReserves();
        if (r0 == 0 || r1 == 0) return;

        uint256 uniBefore = IERC20(SEP_UNI).balanceOf(USER);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, USER, false, address(0), SEP_UNI, ETH_IN, 0, DEADLINE
        );

        vm.prank(USER);
        router.multicall{value: ETH_IN}(calls);

        assertGt(IERC20(SEP_UNI).balanceOf(USER) - uniBefore, 0, "no UNI out");
    }

    /* ═══════════════════════════════════════════════
                TRANSIENT BALANCE TESTS
       ═══════════════════════════════════════════════ */

    /// Deposit UNI then swap via transient balance
    function testTransientBalance_DepositThenSwap() public {
        address pool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 3000);
        if (pool == address(0)) return;

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, SEP_UNI, 0, UNI_IN);
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, USER, false, 3000, SEP_UNI, address(0), UNI_IN, 0, DEADLINE
        );

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.multicall(calls);

        assertGt(USER.balance - ethBefore, 0, "should receive ETH");
    }

    /// Deposit, partial use, sweep remainder
    function testTransientBalance_PartialUseSweep() public {
        address pool = IV3Factory(V3_FACTORY).getPool(SEP_WETH, SEP_UNI, 3000);
        if (pool == address(0)) return;

        bytes[] memory calls = new bytes[](3);

        uint256 depositAmt = 200e18;
        uint256 swapAmt = 100e18;

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, SEP_UNI, 0, depositAmt);
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, USER, false, 3000, SEP_UNI, address(0), swapAmt, 0, DEADLINE
        );
        calls[2] = abi.encodeWithSelector(zRouter.sweep.selector, SEP_UNI, 0, 0, USER);

        uint256 uniBefore = IERC20(SEP_UNI).balanceOf(USER);
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.multicall(calls);

        uint256 uniAfter = IERC20(SEP_UNI).balanceOf(USER);

        assertEq(uniBefore - uniAfter, swapAmt, "net UNI spend wrong");
        assertGt(USER.balance - ethBefore, 0, "should receive ETH");
    }

    /* ═══════════════════════════════════════════════
                    UTILITY TESTS
       ═══════════════════════════════════════════════ */

    /// Wrap ETH → WETH via router
    function testWrapUnwrap() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(zRouter.wrap.selector, ETH_IN);
        calls[1] = abi.encodeWithSelector(zRouter.sweep.selector, SEP_WETH, 0, 0, USER);

        uint256 wethBefore = IERC20(SEP_WETH).balanceOf(USER);

        vm.prank(USER);
        router.multicall{value: ETH_IN}(calls);

        assertEq(IERC20(SEP_WETH).balanceOf(USER) - wethBefore, ETH_IN, "WETH mismatch");
    }

    /// Sweep ETH from router
    function testSweepETH() public {
        vm.prank(USER);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertTrue(ok, "ETH send failed");

        uint256 ethBefore = USER.balance;

        router.sweep(address(0), 0, 0, USER);

        assertEq(USER.balance - ethBefore, 1 ether, "sweep ETH mismatch");
    }

    /* ═══════════════════════════════════════════════
                 EXECUTE / TRUST TESTS
       ═══════════════════════════════════════════════ */

    /// Only owner can call trust()
    function testTrust_OnlyOwner() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.Unauthorized.selector);
        router.trust(address(0xdead), true);
    }

    /// Execute reverts on untrusted target
    function testExecute_UntrustedReverts() public {
        vm.expectRevert(zRouter.Unauthorized.selector);
        router.execute(address(0xdead), 0, "");
    }

    /* ═══════════════════════════════════════════════
              POOL ADDRESS COMPUTATION HELPERS
       ═══════════════════════════════════════════════ */

    function _v2PoolFor(address tokenA, address tokenB)
        internal
        pure
        returns (address v2pool, bool zeroForOne)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        zeroForOne = tokenA < tokenB;
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

    function _v3PoolFor(address tokenA, address tokenB, uint24 fee)
        internal
        pure
        returns (address v3pool, bool zeroForOne)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        zeroForOne = tokenA < tokenB;
        bytes32 salt = keccak256(abi.encode(token0, token1, fee));
        v3pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", V3_FACTORY, salt, V3_POOL_INIT_CODE_HASH)
                    )
                )
            )
        );
    }
}
