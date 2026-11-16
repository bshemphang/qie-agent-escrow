// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgentEscrow — trustless escrow for AI-agent work on QIE
/// @notice A client posts a task with a QIE bounty locked in escrow. An agent
/// claims it, delivers a result (as a content hash), and the client approves
/// to release the bounty. If the two sides disagree, a referee named at
/// posting time decides who gets the bounty. Timeouts protect both sides:
/// an unclaimed-or-undelivered task refunds the client after the deadline,
/// and a delivered task the client ignores releases to the agent after a
/// review window.
/// @dev Built for QIE Hackathon 3.0, track: AI + Autonomous Agents.
/// Testnet: QIE Testnet, chain ID 1983. Mainnet: QIE Mainnet, chain ID 1990.
contract AgentEscrow is ReentrancyGuard {
    /// @notice How long a client has to approve or dispute a delivery before
    /// the agent can release the bounty themselves.
    uint256 public constant REVIEW_WINDOW = 7 days;

    enum Status {
        Open, // posted, bounty locked, waiting for an agent to claim
        Claimed, // an agent claimed it, work in progress
        Delivered, // agent delivered a result hash, waiting on the client
        Completed, // client approved, bounty paid to the agent
        Disputed, // client or agent raised a dispute, waiting on the referee
        Resolved, // referee decided, bounty paid out one way or the other
        Cancelled, // client cancelled before any claim, bounty refunded
        Refunded // deadline passed with no delivery, bounty refunded
    }

    struct Task {
        address client;
        address agent;
        address referee;
        uint256 bounty;
        uint256 deadline;
        bytes32 deliveryHash;
        string title;
        string description;
        Status status;
    }

    uint256 public taskCount;
    mapping(uint256 => Task) private tasks;

    event TaskPosted(
        uint256 indexed taskId,
        address indexed client,
        address indexed referee,
        uint256 bounty,
        uint256 deadline
    );
    event TaskCancelled(uint256 indexed taskId, address indexed client);
    event TaskClaimed(uint256 indexed taskId, address indexed agent);
    event TaskDelivered(uint256 indexed taskId, address indexed agent, bytes32 deliveryHash);
    event TaskApproved(uint256 indexed taskId, address indexed client, uint256 bounty);
    event TaskDisputed(uint256 indexed taskId, address indexed by);
    event DisputeResolved(uint256 indexed taskId, address indexed referee, bool paidAgent);
    event TaskRefunded(uint256 indexed taskId, address indexed client, uint256 bounty);
    event BountyReleasedAfterTimeout(uint256 indexed taskId, address indexed agent, uint256 bounty);

    error ZeroBounty();
    error DeadlineInPast();
    error DeadlinePassed();
    error InvalidReferee();
    error EmptyTitle();
    error TaskNotFound();
    error NotClient();
    error NotAgent();
    error NotReferee();
    error NotParty();
    error WrongStatus(Status expected, Status actual);
    error RefereeIsClient();
    error ClientCannotClaim();
    error RefereeCannotClaim();
    error DeadlineNotPassed();

    modifier taskExists(uint256 taskId) {
        if (taskId >= taskCount) revert TaskNotFound();
        _;
    }

    /// @notice Post a task and lock its bounty in escrow.
    /// @param referee The address that decides disputes. Must not be the client.
    /// @param title Short human-readable title (shown in the app).
    /// @param description What the agent has to do.
    /// @param deadline Unix timestamp by which the agent must deliver.
    /// @return taskId The new task's id.
    function postTask(
        address referee,
        string calldata title,
        string calldata description,
        uint256 deadline
    ) external payable returns (uint256 taskId) {
        if (msg.value == 0) revert ZeroBounty();
        if (deadline <= block.timestamp) revert DeadlineInPast();
        if (referee == address(0)) revert InvalidReferee();
        if (referee == msg.sender) revert RefereeIsClient();
        if (bytes(title).length == 0) revert EmptyTitle();

        taskId = taskCount;
        taskCount += 1;

        tasks[taskId] = Task({
            client: msg.sender,
            agent: address(0),
            referee: referee,
            bounty: msg.value,
            deadline: deadline,
            deliveryHash: bytes32(0),
            title: title,
            description: description,
            status: Status.Open
        });

        emit TaskPosted(taskId, msg.sender, referee, msg.value, deadline);
    }

    /// @notice Cancel an unclaimed task and refund the bounty to the client.
    function cancelTask(uint256 taskId) external taskExists(taskId) nonReentrant {
        Task storage task = tasks[taskId];
        if (msg.sender != task.client) revert NotClient();
        if (task.status != Status.Open) revert WrongStatus(Status.Open, task.status);

        task.status = Status.Cancelled;
        uint256 bounty = task.bounty;
        task.bounty = 0;

        emit TaskCancelled(taskId, task.client);

        (bool ok, ) = task.client.call{value: bounty}("");
        require(ok, "refund failed");
    }

    /// @notice Claim an open task. The client and the referee cannot claim it.
    function claimTask(uint256 taskId) external taskExists(taskId) {
        Task storage task = tasks[taskId];
        if (task.status != Status.Open) revert WrongStatus(Status.Open, task.status);
        if (msg.sender == task.client) revert ClientCannotClaim();
        if (msg.sender == task.referee) revert RefereeCannotClaim();

        task.agent = msg.sender;
        task.status = Status.Claimed;

        emit TaskClaimed(taskId, msg.sender);
    }

    /// @notice Deliver a result. The result itself lives off chain; only its
    /// hash is stored, so the delivery is verifiable without bloating the chain.
    /// @param resultHash keccak256 of the delivered work (file, text, link, ...).
    function deliverTask(uint256 taskId, bytes32 resultHash) external taskExists(taskId) {
        Task storage task = tasks[taskId];
        if (msg.sender != task.agent) revert NotAgent();
        if (task.status != Status.Claimed) revert WrongStatus(Status.Claimed, task.status);
        if (block.timestamp > task.deadline) revert DeadlinePassed();

        task.deliveryHash = resultHash;
        task.status = Status.Delivered;

        emit TaskDelivered(taskId, msg.sender, resultHash);
    }

    /// @notice Approve a delivery and release the bounty to the agent.
    function approveTask(uint256 taskId) external taskExists(taskId) nonReentrant {
        Task storage task = tasks[taskId];
        if (msg.sender != task.client) revert NotClient();
        if (task.status != Status.Delivered) revert WrongStatus(Status.Delivered, task.status);

        task.status = Status.Completed;
        uint256 bounty = task.bounty;
        task.bounty = 0;

        emit TaskApproved(taskId, task.client, bounty);

        (bool ok, ) = task.agent.call{value: bounty}("");
        require(ok, "payout failed");
    }

    /// @notice Raise a dispute over a delivery. Either the client or the
    /// agent can dispute; the named referee then decides.
    function disputeTask(uint256 taskId) external taskExists(taskId) {
        Task storage task = tasks[taskId];
        if (msg.sender != task.client && msg.sender != task.agent) revert NotParty();
        if (task.status != Status.Delivered) revert WrongStatus(Status.Delivered, task.status);

        task.status = Status.Disputed;

        emit TaskDisputed(taskId, msg.sender);
    }

    /// @notice Resolve a dispute. `payAgent == true` pays the bounty to the
    /// agent, `false` refunds it to the client. Only the named referee.
    function resolveDispute(uint256 taskId, bool payAgent) external taskExists(taskId) nonReentrant {
        Task storage task = tasks[taskId];
        if (msg.sender != task.referee) revert NotReferee();
        if (task.status != Status.Disputed) revert WrongStatus(Status.Disputed, task.status);

        task.status = Status.Resolved;
        uint256 bounty = task.bounty;
        task.bounty = 0;

        address payable recipient = payAgent ? payable(task.agent) : payable(task.client);

        emit DisputeResolved(taskId, task.referee, payAgent);

        (bool ok, ) = recipient.call{value: bounty}("");
        require(ok, "payout failed");
    }

    /// @notice Refund a claimed task whose deadline passed with no delivery.
    /// Anyone can call it; the money always goes back to the client.
    function refundTask(uint256 taskId) external taskExists(taskId) nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != Status.Claimed) revert WrongStatus(Status.Claimed, task.status);
        if (block.timestamp <= task.deadline) revert DeadlineNotPassed();

        task.status = Status.Refunded;
        uint256 bounty = task.bounty;
        task.bounty = 0;

        emit TaskRefunded(taskId, task.client, bounty);

        (bool ok, ) = task.client.call{value: bounty}("");
        require(ok, "refund failed");
    }

    /// @notice Release the bounty to the agent when a delivered task has sat
    /// unreviewed past the deadline plus the review window. Stops a client
    /// from ghosting an agent forever.
    function releaseAfterTimeout(uint256 taskId) external taskExists(taskId) nonReentrant {
        Task storage task = tasks[taskId];
        if (msg.sender != task.agent) revert NotAgent();
        if (task.status != Status.Delivered) revert WrongStatus(Status.Delivered, task.status);
        if (block.timestamp <= task.deadline + REVIEW_WINDOW) revert DeadlineNotPassed();

        task.status = Status.Completed;
        uint256 bounty = task.bounty;
        task.bounty = 0;

        emit BountyReleasedAfterTimeout(taskId, task.agent, bounty);

        (bool ok, ) = task.agent.call{value: bounty}("");
        require(ok, "payout failed");
    }

    /// @notice Read a task's full details.
    function getTask(uint256 taskId) external view taskExists(taskId) returns (Task memory) {
        return tasks[taskId];
    }
}
