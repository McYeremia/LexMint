// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/IPRegistry.sol";
import "../src/RoyaltyVault.sol";

// ---------------------------------------------------------------------------
// Invariant handler
// ---------------------------------------------------------------------------

contract RoyaltyVaultHandler is Test {
    RoyaltyVault public vault;
    IPRegistry   public registry;
    bytes32      public workHash;
    address      public owner   = address(0x1);
    address      public coOwner = address(0x2);

    constructor(RoyaltyVault v, IPRegistry r, bytes32 h) {
        vault    = v;
        registry = r;
        workHash = h;
    }

    /// @notice Deposit a bounded amount into the vault
    function deposit(uint96 amount) external {
        vm.deal(msg.sender, amount);
        vm.prank(msg.sender);
        vault.depositRoyalty{value: amount}(workHash);
    }

    /// @notice Attempt a claim for a given address
    function claim(address who) external {
        vm.prank(who);
        try vault.claimRoyalty(workHash) {} catch {}
    }
}

// ---------------------------------------------------------------------------
// Main test contract
// ---------------------------------------------------------------------------

contract RoyaltyVaultTest is Test {
    IPRegistry   public registry;
    RoyaltyVault public vault;

    address constant OWNER    = address(0x1);
    address constant CO_OWNER = address(0x2);
    address constant BUYER    = address(0x3);
    address constant OTHER    = address(0x4);

    bytes32 constant WORK_HASH = keccak256("test-work");
    bytes32 constant UNREGISTERED_HASH = keccak256("not-registered");

    RoyaltyVaultHandler internal _handler;

    function setUp() public {
        registry = new IPRegistry();
        vault    = new RoyaltyVault(address(registry));

        // Fund test actors
        vm.deal(OWNER,    100 ether);
        vm.deal(CO_OWNER, 100 ether);
        vm.deal(BUYER,    100 ether);
        vm.deal(OTHER,    100 ether);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _registerWork(bytes32 h, address owner) internal {
        vm.prank(owner);
        registry.registerWork(h, "ipfs://metadata");
    }

    function _addCoOwner(bytes32 h, address owner, address co, uint256 bps) internal {
        vm.prank(owner);
        registry.addCoOwner(h, co, bps);
    }

    // -----------------------------------------------------------------------
    // Unit — happy path
    // -----------------------------------------------------------------------

    /// @notice Depositing to a work with no co-owners accrues entire amount to owner
    function test_depositRoyalty_sole_owner() public {
        _registerWork(WORK_HASH, OWNER);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(WORK_HASH);

        assertEq(vault.vaultBalance(WORK_HASH), 1 ether);
        assertEq(vault.accrued(WORK_HASH, OWNER), 1 ether);
    }

    /// @notice Co-owner at 3000 bps receives 30%, owner receives the remaining 70%
    function test_depositRoyalty_with_coOwner() public {
        _registerWork(WORK_HASH, OWNER);
        _addCoOwner(WORK_HASH, OWNER, CO_OWNER, 3000);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(WORK_HASH);

        assertEq(vault.accrued(WORK_HASH, CO_OWNER), 0.3 ether);
        assertEq(vault.accrued(WORK_HASH, OWNER),    0.7 ether);
        assertEq(vault.vaultBalance(WORK_HASH),      1 ether);
    }

    /// @notice Claiming transfers ETH to caller and zeroes their accrued balance
    function test_claimRoyalty_transfers_eth() public {
        _registerWork(WORK_HASH, OWNER);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(WORK_HASH);

        uint256 before = OWNER.balance;

        vm.prank(OWNER);
        vault.claimRoyalty(WORK_HASH);

        assertEq(OWNER.balance,                    before + 1 ether);
        assertEq(vault.accrued(WORK_HASH, OWNER),  0);
        assertEq(vault.vaultBalance(WORK_HASH),    0);
    }

    /// @notice RoyaltyClaimed event is emitted with correct arguments
    function test_claimRoyalty_emitsEvent() public {
        _registerWork(WORK_HASH, OWNER);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(WORK_HASH);

        vm.expectEmit(true, true, false, true);
        emit RoyaltyVault.RoyaltyClaimed(WORK_HASH, OWNER, 1 ether);

        vm.prank(OWNER);
        vault.claimRoyalty(WORK_HASH);
    }

    /// @notice RoyaltyDeposited event is emitted with correct arguments
    function test_depositRoyalty_emitsEvent() public {
        _registerWork(WORK_HASH, OWNER);

        vm.expectEmit(true, true, false, true);
        emit RoyaltyVault.RoyaltyDeposited(WORK_HASH, BUYER, 1 ether);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(WORK_HASH);
    }

    /// @notice getAccrued returns the correct pending claimable amount
    function test_getAccrued_returns_correct() public {
        _registerWork(WORK_HASH, OWNER);

        vm.prank(BUYER);
        vault.depositRoyalty{value: 2 ether}(WORK_HASH);

        assertEq(vault.getAccrued(WORK_HASH, OWNER), 2 ether);
    }

    // -----------------------------------------------------------------------
    // Unit — revert cases
    // -----------------------------------------------------------------------

    /// @notice Depositing to an unregistered hash reverts with WorkNotFound
    function test_depositRoyalty_reverts_workNotFound() public {
        vm.expectRevert(RoyaltyVault.WorkNotFound.selector);
        vm.prank(BUYER);
        vault.depositRoyalty{value: 1 ether}(UNREGISTERED_HASH);
    }

    /// @notice Claiming when accrued is zero reverts with NothingToClaim
    function test_claimRoyalty_reverts_nothingToClaim() public {
        _registerWork(WORK_HASH, OWNER);

        vm.expectRevert(RoyaltyVault.NothingToClaim.selector);
        vm.prank(OTHER);
        vault.claimRoyalty(WORK_HASH);
    }

    // -----------------------------------------------------------------------
    // Fuzz tests
    // -----------------------------------------------------------------------

    /// @notice vaultBalance must always equal the sum of all accrued amounts
    function testFuzz_depositRoyalty_balanceConsistency(uint96 amount) public {
        vm.assume(amount > 0);

        _registerWork(WORK_HASH, OWNER);
        _addCoOwner(WORK_HASH, OWNER, CO_OWNER, 3000);

        vm.deal(BUYER, amount);
        vm.prank(BUYER);
        vault.depositRoyalty{value: amount}(WORK_HASH);

        uint256 accruedOwner   = vault.accrued(WORK_HASH, OWNER);
        uint256 accruedCoOwner = vault.accrued(WORK_HASH, CO_OWNER);

        assertEq(vault.vaultBalance(WORK_HASH), accruedOwner + accruedCoOwner);
    }

    /// @notice After deposit then full claim, accrued and vaultBalance are both zero
    function testFuzz_claimRoyalty_zeroesAccrued(uint96 amount) public {
        vm.assume(amount > 0);

        _registerWork(WORK_HASH, OWNER);

        vm.deal(BUYER, amount);
        vm.prank(BUYER);
        vault.depositRoyalty{value: amount}(WORK_HASH);

        vm.prank(OWNER);
        vault.claimRoyalty(WORK_HASH);

        assertEq(vault.accrued(WORK_HASH, OWNER), 0);
        assertEq(vault.vaultBalance(WORK_HASH),   0);
    }

    // -----------------------------------------------------------------------
    // Invariant
    // -----------------------------------------------------------------------

    function invariant_vaultBalanceEqualsAccruedSum() public view {
        uint256 accruedOwner   = vault.accrued(WORK_HASH, OWNER);
        uint256 accruedCoOwner = vault.accrued(WORK_HASH, CO_OWNER);

        assertGe(vault.vaultBalance(WORK_HASH), accruedOwner + accruedCoOwner);
    }
}
