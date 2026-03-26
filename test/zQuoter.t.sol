// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Fork tests that exercise zQuoter calldata builders end-to-end
///         against the deployed zRouter on mainnet.
contract zQuoterTest is Test {
    zQuoter quoter;
    uint256 DEADLINE;

    address constant VITALIK = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;
    address constant WETH_WHALE = 0x8EB8a3b98659Cce290402893d0123abb75E3ab28;

    uint256 constant ETH_IN = 0.05 ether;
    uint256 constant USDC_IN = 100e6;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        quoter = new zQuoter();
        DEADLINE = block.timestamp + 20 minutes;

        vm.deal(VITALIK, 10 ether);

        // Give Vitalik some USDC and approve the deployed router
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(VITALIK, 1000e6);

        vm.startPrank(VITALIK);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);
        IERC20(WETH).approve(ZROUTER, type(uint256).max);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // getQuotes
    // ══════════════════════════════════════════════════════════════════════════

    function testGetQuotes_ExactIn_ETHtoUSDC() public view {
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), USDC, ETH_IN);

        assertGt(best.amountOut, 0, "best quote should have output");
        assertEq(best.amountIn, ETH_IN, "best quote input should match");
        assertGt(quotes.length, 0, "should have multiple quotes");
    }

    function testGetQuotes_ExactOut_ETHtoUSDC() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, address(0), USDC, 50e6);

        assertGt(best.amountIn, 0, "best quote should require input");
        assertEq(best.amountOut, 50e6, "best quote output should match target");
    }

    function testGetQuotes_ExactIn_USDCtoETH() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, USDC, address(0), USDC_IN);

        assertGt(best.amountOut, 0, "should get ETH output");
    }

    function testGetQuotes_ERC20toERC20() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, USDC, WETH, USDC_IN);

        assertGt(best.amountOut, 0, "USDC->WETH should have output");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // quoteCurve
    // ══════════════════════════════════════════════════════════════════════════

    function testQuoteCurve_ExactIn_ETHtoWETH_Returns_Zero() public view {
        // ETH<->WETH is 1:1, quoteCurve should return 0 (let base path handle)
        (uint256 amountIn, uint256 amountOut, address pool,,,,) =
            quoter.quoteCurve(false, address(0), WETH, 1 ether, 8);

        assertEq(pool, address(0), "ETH/WETH should not route via Curve");
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
    }

    function testQuoteCurve_ExactIn_ZeroAmount() public view {
        (,, address pool,,,,) = quoter.quoteCurve(false, USDC, USDT, 0, 8);
        assertEq(pool, address(0), "zero amount should return no pool");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwap — ExactIn
    // ══════════════════════════════════════════════════════════════════════════

    function testBuildBestSwap_ExactIn_ETHtoUSDC() public {
        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(VITALIK, false, address(0), USDC, ETH_IN, 50, DEADLINE);

        assertGt(best.amountOut, 0, "quote should have output");
        assertGt(callData.length, 0, "callData should be non-empty");
        assertGt(amountLimit, 0, "amountLimit should be non-zero");
        assertEq(msgValue, ETH_IN, "exactIn ETH: msgValue should be swapAmount");

        // Execute the built calldata against the deployed router
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "router call should succeed");

        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;
        assertGt(usdcDelta, 0, "should receive USDC");
        assertGe(usdcDelta, amountLimit, "should receive at least amountLimit");
    }

    function testBuildBestSwap_ExactIn_USDCtoETH() public {
        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(VITALIK, false, USDC, address(0), USDC_IN, 50, DEADLINE);

        assertGt(best.amountOut, 0, "quote should have ETH output");
        assertEq(msgValue, 0, "ERC20 in: msgValue should be 0");

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "router call should succeed");

        uint256 ethDelta = VITALIK.balance - ethBefore;
        assertGt(ethDelta, 0, "should receive ETH");
        assertGe(ethDelta, amountLimit, "should receive at least amountLimit");
    }

    function testBuildBestSwap_ExactIn_ERC20toERC20() public {
        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(VITALIK, false, USDC, WETH, USDC_IN, 50, DEADLINE);

        assertGt(best.amountOut, 0, "should have WETH output");
        assertEq(msgValue, 0, "ERC20 in: msgValue should be 0");

        uint256 wethBefore = IERC20(WETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "router call should succeed");

        uint256 wethDelta = IERC20(WETH).balanceOf(VITALIK) - wethBefore;
        assertGt(wethDelta, 0, "should receive WETH");
        assertGe(wethDelta, amountLimit, "should receive at least amountLimit");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwap — ExactOut
    // ══════════════════════════════════════════════════════════════════════════

    function testBuildBestSwap_ExactOut_ETHtoUSDC() public {
        uint256 targetUSDC = 50e6;

        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(VITALIK, true, address(0), USDC, targetUSDC, 50, DEADLINE);

        assertGt(best.amountIn, 0, "should require ETH input");
        assertEq(msgValue, amountLimit, "exactOut ETH: msgValue should be amountLimit");
        assertGt(callData.length, 0, "callData should be non-empty");

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "router call should succeed");

        uint256 usdcDelta = IERC20(USDC).balanceOf(VITALIK) - usdcBefore;
        uint256 ethSpent = ethBefore - VITALIK.balance;

        assertEq(usdcDelta, targetUSDC, "should receive exact target USDC");
        assertLe(ethSpent, amountLimit, "should not spend more than amountLimit");
    }

    function testBuildBestSwap_ExactOut_USDCtoETH() public {
        uint256 targetETH = 0.01 ether;

        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(VITALIK, true, USDC, address(0), targetETH, 50, DEADLINE);

        assertGt(best.amountIn, 0, "should require USDC input");
        assertEq(msgValue, 0, "ERC20 in: msgValue should be 0");

        uint256 ethBefore = VITALIK.balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(callData);
        assertTrue(ok, "router call should succeed");

        uint256 ethDelta = VITALIK.balance - ethBefore;
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(VITALIK);

        assertEq(ethDelta, targetETH, "should receive exact target ETH");
        assertLe(usdcSpent, amountLimit, "should not spend more than amountLimit");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwap — slippage / limit helper
    // ══════════════════════════════════════════════════════════════════════════

    function testSlippageLimit_ExactIn() public pure {
        uint256 quoted = 1000e6; // 1000 USDC
        uint256 bps = 50; // 0.5%
        uint256 minOut = SlippageLib.limit(false, quoted, bps);
        assertEq(minOut, (quoted * 9950) / 10000, "minOut = quoted * (1 - 50bps)");
    }

    function testSlippageLimit_ExactOut() public pure {
        uint256 quoted = 1 ether;
        uint256 bps = 50;
        uint256 maxIn = SlippageLib.limit(true, quoted, bps);
        // ceil(quoted * 10050 / 10000)
        assertEq(maxIn, (quoted * 10050 + 9999) / 10000, "maxIn = ceil(quoted * (1 + 50bps))");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwap — NoRoute revert
    // ══════════════════════════════════════════════════════════════════════════

    function testBuildBestSwap_NoRoute_Reverts() public {
        // Use a random non-existent token pair
        address fakeToken = address(0xdead);
        vm.expectRevert(zQuoter.NoRoute.selector);
        quoter.buildBestSwap(VITALIK, false, fakeToken, USDC, 1e18, 50, DEADLINE);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwapViaETHMulticall — single-hop fast path
    // ══════════════════════════════════════════════════════════════════════════

    function testMulticall_SingleHop_ExactIn_ETHtoUSDC() public {
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), USDC, ETH_IN, 50, DEADLINE, 0, 0, address(0)
        );

        assertGt(a.amountOut, 0, "leg A should have output");
        assertEq(b.amountIn, 0, "single-hop: leg B should be empty");
        assertEq(calls.length, 1, "single-hop should have 1 call");
        assertGt(multicall.length, 0, "multicall data should be non-empty");
        assertEq(msgValue, ETH_IN, "exactIn ETH: msgValue = swapAmount");

        // Execute via deployed router
        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(IERC20(USDC).balanceOf(VITALIK) - usdcBefore, 0, "should receive USDC");
    }

    function testMulticall_SingleHop_ExactIn_USDCtoETH() public {
        (,, bytes[] memory calls, bytes memory multicall, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, USDC, address(0), USDC_IN, 50, DEADLINE, 0, 0, address(0)
        );

        assertEq(calls.length, 1, "single-hop should have 1 call");
        assertEq(msgValue, 0, "ERC20 in: no ETH needed");

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(VITALIK.balance - ethBefore, 0, "should receive ETH");
    }

    function testMulticall_SingleHop_ExactOut_ETHtoUSDC() public {
        uint256 targetUSDC = 50e6;

        (zQuoter.Quote memory a,, bytes[] memory calls, bytes memory multicall, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, true, address(0), USDC, targetUSDC, 50, DEADLINE, 0, 0, address(0)
        );

        assertEq(calls.length, 1, "single-hop should have 1 call");
        assertGt(msgValue, 0, "exactOut ETH needs value");

        uint256 usdcBefore = IERC20(USDC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertEq(
            IERC20(USDC).balanceOf(VITALIK) - usdcBefore, targetUSDC, "should receive exact USDC"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwapViaETHMulticall — 2-hop via hub
    // ══════════════════════════════════════════════════════════════════════════

    function testMulticall_TwoHop_ExactIn() public {
        // Use a pair that likely needs a hub (e.g. DAI -> WBTC)
        // Fund Vitalik with DAI
        address DAI_WHALE = 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf;
        vm.prank(DAI_WHALE);
        IERC20(DAI).transfer(VITALIK, 500e18);
        vm.prank(VITALIK);
        IERC20(DAI).approve(ZROUTER, type(uint256).max);

        // Try to route DAI -> WBTC. If direct route exists, this will be single-hop.
        // Either way the calldata should execute correctly.
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, DAI, WBTC, 100e18, 50, DEADLINE, 0, 0, address(0)
        );

        assertGt(a.amountOut, 0, "leg A should have output");

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertGt(IERC20(WBTC).balanceOf(VITALIK) - wbtcBefore, 0, "should receive WBTC");
    }

    function testMulticall_TwoHop_ExactOut() public {
        // Target a small amount of WBTC via exactOut from ETH
        uint256 targetWBTC = 1000; // 0.00001 WBTC (tiny to avoid needing lots of ETH)

        // Try via multicall builder
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, true, address(0), WBTC, targetWBTC, 100, DEADLINE, 0, 0, address(0)
        );

        assertGt(a.amountIn, 0, "leg A should require input");

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(VITALIK);
        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        uint256 wbtcDelta = IERC20(WBTC).balanceOf(VITALIK) - wbtcBefore;
        assertGe(wbtcDelta, targetWBTC, "should receive at least target WBTC");
        assertLt(ethBefore - VITALIK.balance, msgValue + 1, "should not overspend ETH");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwapViaETHMulticall — ETH<->WETH wrap/unwrap
    // ══════════════════════════════════════════════════════════════════════════

    function testMulticall_WrapETH() public {
        (
            zQuoter.Quote memory qa,,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), WETH, 1 ether, 50, DEADLINE, 0, 0, address(0)
        );

        assertEq(uint8(qa.source), uint8(zQuoter.AMM.WETH_WRAP), "should be WETH_WRAP");
        assertEq(qa.amountIn, 1 ether, "amountIn should match");
        assertEq(qa.amountOut, 1 ether, "amountOut should match (1:1)");
        assertEq(calls.length, 2, "wrap path should have 2 calls");
        assertEq(msgValue, 1 ether, "msgValue should be swapAmount");

        uint256 wethBefore = IERC20(WETH).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertEq(IERC20(WETH).balanceOf(VITALIK) - wethBefore, 1 ether, "should receive 1 WETH");
    }

    function testMulticall_UnwrapWETH() public {
        // Give Vitalik some WETH
        vm.prank(WETH_WHALE);
        IERC20(WETH).transfer(VITALIK, 0.5 ether);

        (
            zQuoter.Quote memory qa,,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, WETH, address(0), 0.5 ether, 50, DEADLINE, 0, 0, address(0)
        );

        assertEq(uint8(qa.source), uint8(zQuoter.AMM.WETH_WRAP), "should be WETH_WRAP");
        assertEq(calls.length, 3, "unwrap path should have 3 calls");
        assertEq(msgValue, 0, "WETH in: no ETH needed");

        uint256 ethBefore = VITALIK.balance;

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "multicall should succeed");

        assertEq(VITALIK.balance - ethBefore, 0.5 ether, "should receive 0.5 ETH");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwapViaETHMulticall — error cases
    // ══════════════════════════════════════════════════════════════════════════

    function testMulticall_ZeroAmount_ReturnsEmpty() public view {
        (zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory calls,,) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), USDC, 0, 50, DEADLINE, 0, 0, address(0)
        );
        assertEq(a.amountOut, 0, "zero input should produce zero output");
        assertEq(b.amountOut, 0, "leg B should be empty");
        assertEq(calls.length, 0, "no calls for zero amount");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // buildBestSwapViaETHMulticall — msgValue consistency
    // ══════════════════════════════════════════════════════════════════════════

    function testMulticall_MsgValue_ERC20In_IsZero() public view {
        (,,,, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, USDC, address(0), USDC_IN, 50, DEADLINE, 0, 0, address(0)
        );
        assertEq(msgValue, 0, "ERC20 input should not require ETH");
    }

    function testMulticall_MsgValue_ETHIn_ExactIn() public view {
        (,,,, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), USDC, ETH_IN, 50, DEADLINE, 0, 0, address(0)
        );
        assertEq(msgValue, ETH_IN, "exactIn ETH should send swapAmount");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // build3HopMulticall
    // ══════════════════════════════════════════════════════════════════════════

    function testBuild3Hop_ExactIn_ETHtoWBTC() public {
        // 3-hop: ETH -> MID1 -> MID2 -> WBTC
        (
            zQuoter.Quote memory a,
            zQuoter.Quote memory b,
            zQuoter.Quote memory c,
            bytes[] memory calls,
            bytes memory multicall,
            uint256 msgValue
        ) = quoter.build3HopMulticall(VITALIK, address(0), WBTC, ETH_IN, 100, DEADLINE);

        assertGt(a.amountOut, 0, "leg A should have output");
        assertGt(b.amountOut, 0, "leg B should have output");
        assertGt(c.amountOut, 0, "leg C should have output");
        assertEq(calls.length, 3, "3-hop should have 3 calls");
        assertGt(multicall.length, 0, "multicall should be non-empty");

        uint256 wbtcBefore = IERC20(WBTC).balanceOf(VITALIK);

        vm.prank(VITALIK);
        (bool ok,) = ZROUTER.call{value: msgValue}(multicall);
        assertTrue(ok, "3-hop multicall should succeed");

        assertGt(IERC20(WBTC).balanceOf(VITALIK) - wbtcBefore, 0, "should receive WBTC");
    }

    function testBuild3Hop_ZeroAmount_ReturnsEmpty() public view {
        (zQuoter.Quote memory a,,,,,) =
            quoter.build3HopMulticall(VITALIK, address(0), WBTC, 0, 100, DEADLINE);
        assertEq(a.amountOut, 0, "zero input should produce zero output");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Comparison: buildBestSwap vs buildBestSwapViaETHMulticall consistency
    // ══════════════════════════════════════════════════════════════════════════

    function testConsistency_BuildBestSwap_vs_Multicall() public view {
        // For a simple single-hop pair, both should produce equivalent results
        (zQuoter.Quote memory bestDirect,,, uint256 msgDirect) =
            quoter.buildBestSwap(VITALIK, false, address(0), USDC, ETH_IN, 50, DEADLINE);

        (zQuoter.Quote memory bestMulti,,,, uint256 msgMulti) = quoter.buildBestSwapViaETHMulticall(
            VITALIK, VITALIK, false, address(0), USDC, ETH_IN, 50, DEADLINE, 0, 0, address(0)
        );

        // Same AMM source
        assertEq(uint8(bestDirect.source), uint8(bestMulti.source), "AMM source should match");
        // Same amount out
        assertEq(bestDirect.amountOut, bestMulti.amountOut, "amountOut should match");
        // Same msg.value
        assertEq(msgDirect, msgMulti, "msgValue should match");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Individual AMM quoters
    // ══════════════════════════════════════════════════════════════════════════

    function testIndividualQuote_ExactIn_AllSources() public view {
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), USDC, ETH_IN);
        assertGt(best.amountOut, 0, "best quote should have output");
        assertGt(quotes.length, 0, "should return multiple quotes");
    }

    function testIndividualQuote_ExactOut() public view {
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, address(0), USDC, 50e6);
        assertGt(best.amountIn, 0, "best quote should have input cost");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

    receive() external payable {}
}
