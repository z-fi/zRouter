// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/arb/zRouter.sol";

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

contract zRouterARBTest is Test {
    uint256 DEADLINE;

    /* ───────────── addresses & constants ───────────── */
    address constant USER = address(0xBEEF);

    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // V2 pair (WETH/USDC) — token0=WETH, token1=USDC
    address constant V2_PAIR = 0xF64Dfe17C8b87F012FCf50FbDA1D62bfA148366a;
    // V3 pool (WETH/USDC) 500 bp
    address constant V3_POOL_500 = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    uint256 constant USDC_IN = 100e6; // 100 USDC
    uint256 constant ETH_IN = 0.05 ether;
    uint256 constant USDC_OUT = 50e6; // 50 USDC exact-out target
    uint256 constant ETH_OUT = 0.01 ether;

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
        return (n + d - 1) / d; // ceil-div
    }

    /* ───────────── setUp ───────────── */
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("arb"));

        routerOwner = tx.origin;
        router = new zRouter();

        // fund USER with ETH and USDC via deal()
        vm.deal(USER, 10 ether);
        deal(ARB_USDC, USER, 10_000e6);

        DEADLINE = block.timestamp + 20 minutes;

        vm.prank(USER);
        IERC20(ARB_USDC).approve(address(router), type(uint256).max);
    }

    /* ═══════════════════════════════════════════════
                          V2 TESTS
       ═══════════════════════════════════════════════ */

    /// V2: USDC → ETH exact-in
    function testV2_ExactIn_USDCtoETH() public {
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV2(USER, false, ARB_USDC, address(0), USDC_IN, 0, DEADLINE);

        assertEq(amountIn, USDC_IN, "amountIn mismatch");
        assertGt(amountOut, 0, "no ETH out");
        assertEq(USER.balance - ethBefore, amountOut, "ETH balance mismatch");
    }

    /// V2: ETH → USDC exact-in
    function testV2_ExactIn_ETHtoUSDC() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV2{value: ETH_IN}(USER, false, address(0), ARB_USDC, ETH_IN, 0, DEADLINE);

        assertEq(amountIn, ETH_IN, "amountIn mismatch");
        assertGt(amountOut, 0, "no USDC out");
        assertEq(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, amountOut, "USDC balance mismatch");
    }

    /// V2: ETH → USDC exact-out
    function testV2_ExactOut_ETHtoUSDC() public {
        uint256 ethBefore = USER.balance;
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        router.swapV2{value: ETH_IN}(USER, true, address(0), ARB_USDC, USDC_OUT, ETH_IN, DEADLINE);

        uint256 usdcDelta = IERC20(ARB_USDC).balanceOf(USER) - usdcBefore;
        uint256 ethSpent = ethBefore - USER.balance;

        assertEq(usdcDelta, USDC_OUT, "USDC exact-out failed");
        assertLt(ethSpent, ETH_IN, "no ETH refund");
        assertGt(ethSpent, 0, "no ETH spent");
    }

    /// V2: USDC → ETH exact-out
    function testV2_ExactOut_USDCtoETH() public {
        // token0=WETH, token1=USDC on this pair
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        // USDC in (token1), ETH out (token0): resIn=r1, resOut=r0
        uint256 needUsdc = _getAmountIn(ETH_OUT, r1, r0);
        uint256 budget = needUsdc + 1e6; // +1 USDC slack

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.swapV2(USER, true, ARB_USDC, address(0), ETH_OUT, budget, DEADLINE);

        assertEq(USER.balance - ethBefore, ETH_OUT, "ETH exact-out failed");
    }

    /// V2: slippage revert
    function testV2_SlippageReverts() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.Slippage.selector);
        router.swapV2{value: ETH_IN}(
            USER, false, address(0), ARB_USDC, ETH_IN, type(uint256).max, DEADLINE
        );
    }

    /// V2: deadline revert
    function testV2_DeadlineReverts() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapV2{value: ETH_IN}(
            USER, false, address(0), ARB_USDC, ETH_IN, 0, block.timestamp - 1
        );
    }

    /* ═══════════════════════════════════════════════
                          V3 TESTS
       ═══════════════════════════════════════════════ */

    /// V3: ETH → USDC exact-in (500 bp pool)
    function testV3_ExactIn_ETHtoUSDC() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        router.swapV3{value: ETH_IN}(USER, false, 500, address(0), ARB_USDC, ETH_IN, 0, DEADLINE);

        assertGt(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, 0, "no USDC out");
    }

    /// V3: USDC → ETH exact-in
    function testV3_ExactIn_USDCtoETH() public {
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.swapV3(USER, false, 500, ARB_USDC, address(0), USDC_IN, 0, DEADLINE);

        assertGt(USER.balance - ethBefore, 0, "no ETH out");
    }

    /// V3: exact-out ETH → USDC
    function testV3_ExactOut_ETHtoUSDC() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        router.swapV3{value: ETH_IN}(
            USER, true, 500, address(0), ARB_USDC, USDC_OUT, ETH_IN, DEADLINE
        );

        assertEq(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, USDC_OUT, "USDC exact-out failed");
    }

    /// V3: exact-out USDC → ETH
    function testV3_ExactOut_USDCtoETH() public {
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.swapV3(USER, true, 500, ARB_USDC, address(0), ETH_OUT, USDC_IN, DEADLINE);

        assertEq(USER.balance - ethBefore, ETH_OUT, "ETH exact-out failed");
    }

    /// V3: 3000 bp fee tier also works
    function testV3_ExactIn_3000bp() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        router.swapV3{value: ETH_IN}(USER, false, 3000, address(0), ARB_USDC, ETH_IN, 0, DEADLINE);

        assertGt(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, 0, "no USDC out");
    }

    /* ═══════════════════════════════════════════════
                          V4 TESTS
       ═══════════════════════════════════════════════ */

    /// V4: ETH → USDC exact-in
    function testV4_ExactIn_ETHtoUSDC() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        (, uint256 amountOut) = router.swapV4{value: ETH_IN}(
            USER, false, 500, 10, address(0), ARB_USDC, ETH_IN, 0, DEADLINE
        );

        assertGt(amountOut, 0, "no USDC out");
        assertEq(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, amountOut, "USDC balance mismatch");
    }

    /// V4: USDC → ETH exact-in
    function testV4_ExactIn_USDCtoETH() public {
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        (, uint256 amountOut) =
            router.swapV4(USER, false, 500, 10, ARB_USDC, address(0), USDC_IN, 0, DEADLINE);

        assertGt(amountOut, 0, "no ETH out");
        assertGt(USER.balance - ethBefore, 0, "ETH balance unchanged");
    }

    /// V4: ETH → USDC exact-out
    function testV4_ExactOut_ETHtoUSDC() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        vm.prank(USER);
        router.swapV4{value: ETH_IN}(
            USER, true, 500, 10, address(0), ARB_USDC, USDC_OUT, ETH_IN, DEADLINE
        );

        assertEq(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, USDC_OUT, "USDC exact-out failed");
    }

    /// V4: USDC → ETH exact-out
    function testV4_ExactOut_USDCtoETH() public {
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.swapV4(USER, true, 500, 10, ARB_USDC, address(0), ETH_OUT, USDC_IN, DEADLINE);

        assertEq(USER.balance - ethBefore, ETH_OUT, "ETH exact-out failed");
    }

    /* ═══════════════════════════════════════════════
                      MULTICALL TESTS
       ═══════════════════════════════════════════════ */

    /// Multicall: single V2 swap
    function testMulticall_SingleV2() public {
        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector, USER, false, address(0), ARB_USDC, ETH_IN, 0, DEADLINE
        );

        vm.prank(USER);
        router.multicall{value: ETH_IN}(calls);

        assertGt(IERC20(ARB_USDC).balanceOf(USER) - usdcBefore, 0, "no USDC out");
    }

    /// Multicall: V2 ETH→USDC then V3 USDC→ETH (round-trip through router)
    function testMulticall_V2thenV3() public {
        // token0=WETH, token1=USDC — ETH in means zeroForOne=true, resIn=r0, resOut=r1
        (uint112 r0, uint112 r1,) = IUniV2PairReserves(V2_PAIR).getReserves();
        uint256 expectedUsdc = _getAmountOut(ETH_IN, r0, r1);

        bytes[] memory calls = new bytes[](2);

        // hop 1: ETH → USDC via V2, output to router
        calls[0] = abi.encodeWithSelector(
            zRouter.swapV2.selector,
            address(router),
            false,
            address(0),
            ARB_USDC,
            ETH_IN,
            0,
            DEADLINE
        );

        // hop 2: USDC → ETH via V3, using transient balance
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector,
            USER,
            false,
            500,
            ARB_USDC,
            address(0),
            expectedUsdc,
            0,
            DEADLINE
        );

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.multicall{value: ETH_IN}(calls);

        assertGt(USER.balance, ethBefore - ETH_IN, "lost all ETH");
    }

    /* ═══════════════════════════════════════════════
                   TRANSIENT BALANCE TESTS
       ═══════════════════════════════════════════════ */

    /// Deposit USDC then swap via transient balance
    function testTransientBalance_DepositThenSwap() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, ARB_USDC, 0, USDC_IN);
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, USER, false, 500, ARB_USDC, address(0), USDC_IN, 0, DEADLINE
        );

        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.multicall(calls);

        assertGt(USER.balance - ethBefore, 0, "should receive ETH");
    }

    /// Deposit, partial use, sweep remainder
    function testTransientBalance_PartialUseSweep() public {
        bytes[] memory calls = new bytes[](3);

        uint256 depositAmt = 200e6;
        uint256 swapAmt = 100e6;

        calls[0] = abi.encodeWithSelector(zRouter.deposit.selector, ARB_USDC, 0, depositAmt);
        calls[1] = abi.encodeWithSelector(
            zRouter.swapV3.selector, USER, false, 500, ARB_USDC, address(0), swapAmt, 0, DEADLINE
        );
        calls[2] = abi.encodeWithSelector(zRouter.sweep.selector, ARB_USDC, 0, 0, USER);

        uint256 usdcBefore = IERC20(ARB_USDC).balanceOf(USER);
        uint256 ethBefore = USER.balance;

        vm.prank(USER);
        router.multicall(calls);

        uint256 usdcAfter = IERC20(ARB_USDC).balanceOf(USER);

        assertEq(usdcBefore - usdcAfter, swapAmt, "net USDC spend wrong");
        assertGt(USER.balance - ethBefore, 0, "should receive ETH");
    }

    /* ═══════════════════════════════════════════════
                     UTILITY TESTS
       ═══════════════════════════════════════════════ */

    /// Wrap ETH → WETH via router
    function testWrapUnwrap() public {
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(zRouter.wrap.selector, ETH_IN);
        calls[1] = abi.encodeWithSelector(zRouter.sweep.selector, ARB_WETH, 0, 0, USER);

        uint256 wethBefore = IERC20(ARB_WETH).balanceOf(USER);

        vm.prank(USER);
        router.multicall{value: ETH_IN}(calls);

        assertEq(IERC20(ARB_WETH).balanceOf(USER) - wethBefore, ETH_IN, "WETH mismatch");
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
}
