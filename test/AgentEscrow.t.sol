// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

/// @notice A malicious agent that tries to re-enter approveTask from its
/// receive() function when the bounty is paid out.
contract ReentrantAgent {
    AgentEscrow public escrow;
    uint256 public taskId;
    bool public reentered;
    bool public reentrySucceeded;

    constructor(AgentEscrow _escrow) {
        escrow = _escrow;
    }

    function claim(uint256 _taskId) external {
        taskId = _taskId;
        escrow.claimTask(_taskId);
    }

    function deliver(uint256 _taskId, bytes32 resultHash) external {
        escrow.deliverTask(_taskId, resultHash);
    }

    receive() external payable {
        reentered = true;
        (bool ok, ) = address(escrow).call(
            abi.encodeWithSignature("approveTask(uint256)", taskId)
        );
        reentrySucceeded = ok;
    }
}

contract AgentEscrowTest is Test {
    AgentEscrow public escrow;

    address public client = makeAddr("client");
    address public agent = makeAddr("agent");
    address public referee = makeAddr("referee");
    address public stranger = makeAddr("stranger");

    uint256 public constant BOUNTY = 1 ether;
    bytes32 public constant RESULT_HASH = keccak256("delivered work: report.pdf");

    function setUp() public {
        escrow = new AgentEscrow();
        vm.deal(client, 100 ether);
        vm.deal(agent, 10 ether);
        vm.deal(referee, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function _postTask() internal returns (uint256 taskId) {
        return _postTaskWithDeadline(block.timestamp + 1 days);
    }

    function _postTaskWithDeadline(uint256 deadline) internal returns (uint256 taskId) {
        vm.prank(client);
        taskId = escrow.postTask{value: BOUNTY}(
            referee,
            "Write a market research brief",
            "Research the top 5 AI note-taking tools and write a 2-page brief.",
            deadline
        );
    }

    function _postClaimDeliver() internal returns (uint256 taskId) {
        taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);
        vm.prank(agent);
        escrow.deliverTask(taskId, RESULT_HASH);
    }

    // ---- posting ----

    function test_PostTaskStoresEverything() public {
        uint256 taskId = _postTask();
        assertEq(escrow.taskCount(), 1);

        AgentEscrow.Task memory task = escrow.getTask(taskId);
        assertEq(task.client, client);
        assertEq(task.agent, address(0));
        assertEq(task.referee, referee);
        assertEq(task.bounty, BOUNTY);
        assertEq(task.title, "Write a market research brief");
        assertEq(uint256(task.status), uint256(AgentEscrow.Status.Open));
        assertEq(address(escrow).balance, BOUNTY);
    }

    function test_PostTaskEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit AgentEscrow.TaskPosted(0, client, referee, BOUNTY, block.timestamp + 1 days);
        vm.prank(client);
        escrow.postTask{value: BOUNTY}(
            referee, "T", "D", block.timestamp + 1 days
        );
    }

    function test_PostTaskRevertsZeroBounty() public {
        vm.prank(client);
        vm.expectRevert(AgentEscrow.ZeroBounty.selector);
        escrow.postTask{value: 0}(referee, "T", "D", block.timestamp + 1 days);
    }

    function test_PostTaskRevertsDeadlineInPast() public {
        vm.prank(client);
        vm.expectRevert(AgentEscrow.DeadlineInPast.selector);
        escrow.postTask{value: BOUNTY}(referee, "T", "D", block.timestamp - 1);
    }

    function test_PostTaskRevertsRefereeIsClient() public {
        vm.prank(client);
        vm.expectRevert(AgentEscrow.RefereeIsClient.selector);
        escrow.postTask{value: BOUNTY}(client, "T", "D", block.timestamp + 1 days);
    }

    function test_PostTaskRevertsZeroReferee() public {
        vm.prank(client);
        vm.expectRevert(AgentEscrow.InvalidReferee.selector);
        escrow.postTask{value: BOUNTY}(address(0), "T", "D", block.timestamp + 1 days);
    }

    function test_PostTaskRevertsEmptyTitle() public {
        vm.prank(client);
        vm.expectRevert(AgentEscrow.EmptyTitle.selector);
        escrow.postTask{value: BOUNTY}(referee, "", "D", block.timestamp + 1 days);
    }

    function test_GetTaskRevertsForMissingId() public {
        vm.expectRevert(AgentEscrow.TaskNotFound.selector);
        escrow.getTask(99);
    }

    // ---- happy path ----

    function test_FullLifecycleApprovePaysAgent() public {
        uint256 taskId = _postClaimDeliver();

        uint256 agentBefore = agent.balance;
        vm.prank(client);
        escrow.approveTask(taskId);

        AgentEscrow.Task memory task = escrow.getTask(taskId);
        assertEq(uint256(task.status), uint256(AgentEscrow.Status.Completed));
        assertEq(agent.balance, agentBefore + BOUNTY);
        assertEq(address(escrow).balance, 0);
    }

    // ---- cancel ----

    function test_CancelBeforeClaimRefundsClient() public {
        uint256 taskId = _postTask();
        uint256 clientBefore = client.balance;

        vm.prank(client);
        escrow.cancelTask(taskId);

        AgentEscrow.Task memory task = escrow.getTask(taskId);
        assertEq(uint256(task.status), uint256(AgentEscrow.Status.Cancelled));
        assertEq(client.balance, clientBefore + BOUNTY);
        assertEq(address(escrow).balance, 0);
    }

    function test_CancelAfterClaimReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEscrow.WrongStatus.selector,
                AgentEscrow.Status.Open,
                AgentEscrow.Status.Claimed
            )
        );
        escrow.cancelTask(taskId);
    }

    function test_CancelByNonClientReverts() public {
        uint256 taskId = _postTask();
        vm.prank(stranger);
        vm.expectRevert(AgentEscrow.NotClient.selector);
        escrow.cancelTask(taskId);
    }

    // ---- claim ----

    function test_DoubleClaimReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEscrow.WrongStatus.selector,
                AgentEscrow.Status.Open,
                AgentEscrow.Status.Claimed
            )
        );
        escrow.claimTask(taskId);
    }

    function test_ClaimByClientReverts() public {
        uint256 taskId = _postTask();
        vm.prank(client);
        vm.expectRevert(AgentEscrow.ClientCannotClaim.selector);
        escrow.claimTask(taskId);
    }

    function test_ClaimByRefereeReverts() public {
        uint256 taskId = _postTask();
        vm.prank(referee);
        vm.expectRevert(AgentEscrow.RefereeCannotClaim.selector);
        escrow.claimTask(taskId);
    }

    // ---- deliver ----

    function test_DeliverByNonAgentReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.prank(stranger);
        vm.expectRevert(AgentEscrow.NotAgent.selector);
        escrow.deliverTask(taskId, RESULT_HASH);
    }

    function test_DeliverAfterDeadlineReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(agent);
        vm.expectRevert(AgentEscrow.DeadlinePassed.selector);
        escrow.deliverTask(taskId, RESULT_HASH);
    }

    function test_DeliverBeforeClaimReverts() public {
        uint256 taskId = _postTask();
        // No agent has claimed yet, so task.agent is address(0) and the
        // caller is not the agent: the NotAgent check fires first.
        vm.prank(agent);
        vm.expectRevert(AgentEscrow.NotAgent.selector);
        escrow.deliverTask(taskId, RESULT_HASH);
    }

    // ---- approve ----

    function test_ApproveBeforeDeliveryReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEscrow.WrongStatus.selector,
                AgentEscrow.Status.Delivered,
                AgentEscrow.Status.Claimed
            )
        );
        escrow.approveTask(taskId);
    }

    function test_ApproveByNonClientReverts() public {
        uint256 taskId = _postClaimDeliver();
        vm.prank(agent);
        vm.expectRevert(AgentEscrow.NotClient.selector);
        escrow.approveTask(taskId);
    }

    // ---- dispute ----

    function test_DisputeByClientThenRefereePaysAgent() public {
        uint256 taskId = _postClaimDeliver();

        vm.prank(client);
        escrow.disputeTask(taskId);
        assertEq(
            uint256(escrow.getTask(taskId).status),
            uint256(AgentEscrow.Status.Disputed)
        );

        uint256 agentBefore = agent.balance;
        vm.prank(referee);
        escrow.resolveDispute(taskId, true);

        assertEq(
            uint256(escrow.getTask(taskId).status),
            uint256(AgentEscrow.Status.Resolved)
        );
        assertEq(agent.balance, agentBefore + BOUNTY);
    }

    function test_DisputeByAgentThenRefereeRefundsClient() public {
        uint256 taskId = _postClaimDeliver();

        vm.prank(agent);
        escrow.disputeTask(taskId);

        uint256 clientBefore = client.balance;
        vm.prank(referee);
        escrow.resolveDispute(taskId, false);

        assertEq(client.balance, clientBefore + BOUNTY);
        assertEq(address(escrow).balance, 0);
    }

    function test_DisputeByNonPartyReverts() public {
        uint256 taskId = _postClaimDeliver();
        vm.prank(stranger);
        vm.expectRevert(AgentEscrow.NotParty.selector);
        escrow.disputeTask(taskId);
    }

    function test_DisputeBeforeDeliveryReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEscrow.WrongStatus.selector,
                AgentEscrow.Status.Delivered,
                AgentEscrow.Status.Claimed
            )
        );
        escrow.disputeTask(taskId);
    }

    function test_ResolveByNonRefereeReverts() public {
        uint256 taskId = _postClaimDeliver();
        vm.prank(client);
        escrow.disputeTask(taskId);

        vm.prank(stranger);
        vm.expectRevert(AgentEscrow.NotReferee.selector);
        escrow.resolveDispute(taskId, true);
    }

    function test_ResolveWhenNotDisputedReverts() public {
        uint256 taskId = _postClaimDeliver();
        vm.prank(referee);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentEscrow.WrongStatus.selector,
                AgentEscrow.Status.Disputed,
                AgentEscrow.Status.Delivered
            )
        );
        escrow.resolveDispute(taskId, true);
    }

    // ---- timeouts ----

    function test_RefundAfterDeadlineNoDelivery() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.warp(block.timestamp + 1 days + 1);
        uint256 clientBefore = client.balance;
        escrow.refundTask(taskId);

        assertEq(
            uint256(escrow.getTask(taskId).status),
            uint256(AgentEscrow.Status.Refunded)
        );
        assertEq(client.balance, clientBefore + BOUNTY);
    }

    function test_RefundBeforeDeadlineReverts() public {
        uint256 taskId = _postTask();
        vm.prank(agent);
        escrow.claimTask(taskId);

        vm.expectRevert(AgentEscrow.DeadlineNotPassed.selector);
        escrow.refundTask(taskId);
    }

    function test_ReleaseAfterTimeoutPaysAgent() public {
        uint256 taskId = _postClaimDeliver();
        AgentEscrow.Task memory task = escrow.getTask(taskId);

        vm.warp(task.deadline + escrow.REVIEW_WINDOW() + 1);
        uint256 agentBefore = agent.balance;
        vm.prank(agent);
        escrow.releaseAfterTimeout(taskId);

        assertEq(
            uint256(escrow.getTask(taskId).status),
            uint256(AgentEscrow.Status.Completed)
        );
        assertEq(agent.balance, agentBefore + BOUNTY);
    }

    function test_ReleaseAfterTimeoutTooEarlyReverts() public {
        uint256 taskId = _postClaimDeliver();
        AgentEscrow.Task memory task = escrow.getTask(taskId);

        vm.warp(task.deadline + escrow.REVIEW_WINDOW() - 1);
        vm.prank(agent);
        vm.expectRevert(AgentEscrow.DeadlineNotPassed.selector);
        escrow.releaseAfterTimeout(taskId);
    }

    function test_ReleaseAfterTimeoutByNonAgentReverts() public {
        uint256 taskId = _postClaimDeliver();
        AgentEscrow.Task memory task = escrow.getTask(taskId);

        vm.warp(task.deadline + escrow.REVIEW_WINDOW() + 1);
        vm.prank(client);
        vm.expectRevert(AgentEscrow.NotAgent.selector);
        escrow.releaseAfterTimeout(taskId);
    }

    // ---- reentrancy ----

    function test_ReentrancyOnApprovePaysOnlyOnce() public {
        ReentrantAgent attacker = new ReentrantAgent(escrow);

        vm.prank(client);
        uint256 taskId = escrow.postTask{value: BOUNTY}(
            referee, "Attack me", "Try to drain the escrow.", block.timestamp + 1 days
        );
        attacker.claim(taskId);
        attacker.deliver(taskId, RESULT_HASH);

        vm.prank(client);
        escrow.approveTask(taskId);

        assertTrue(attacker.reentered(), "attacker never tried to re-enter");
        assertFalse(attacker.reentrySucceeded(), "re-entrant call succeeded");
        assertEq(address(attacker).balance, BOUNTY, "attacker paid more than once");
        assertEq(address(escrow).balance, 0);
    }
}
