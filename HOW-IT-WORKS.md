# How Agent Escrow works — plain English

This is the walkthrough for the demo video and the judges' questions. Every
part of the project is explained here in plain words, so you can explain it
on camera without reading code.

## The problem

Right now, if you hire an AI agent (or a freelancer) to do a job, one side
always takes the risk. Pay first and the agent can disappear. Pay after and
the agent can work for free. There is no neutral middleman that both sides
trust, and hiring a human escrow agent costs money and time.

## The idea

Put the money in a small program on the QIE blockchain — an escrow contract.
The program holds the bounty and only releases it when the rules say so.
Nobody can move the money except by following the rules, and every step is
visible on chain.

## The four people

- **Client** — posts the task and pays the bounty into escrow.
- **Agent** — claims the task and does the work. This can be an AI agent or
  a human; the contract does not care, it only checks wallet addresses.
- **Referee** — a neutral third party the client names when posting. Only
  the referee can settle a dispute. The referee cannot be the client and
  cannot claim the task, so they have no money at stake in the outcome.
- **Anyone** — after a deadline passes with no delivery, anyone can press
  the refund button. The money still goes back to the client, never to the
  person who pressed it.

## The lifecycle, step by step

1. **Post.** The client fills in a title, a description, a bounty in QIE, a
   deadline, and the referee's address. The bounty leaves the client's
   wallet and sits in the contract. The task is now **Open**.
2. **Claim.** An agent claims the open task. Now it is **Claimed**, and
   nobody else can claim it. The client cannot cancel any more — the agent
   has committed to the work.
3. **Deliver.** The agent finishes the work and submits it. The work itself
   (a document, a link, a report) lives off chain. Only its fingerprint —
   the `keccak256` hash — is stored on chain. That means anyone can later
   check that a delivered file matches the hash, without the chain storing
   the whole file. The task is now **Delivered**.
4. **Approve.** The client reads the delivery and approves. The full bounty
   moves to the agent. The task is **Completed**.
5. **Dispute (if needed).** Instead of approving, the client or the agent
   can raise a dispute. The task is **Disputed** and frozen until the
   referee decides. The referee picks one side: pay the agent, or refund
   the client. The task is then **Resolved**.

## The timeout rules (why neither side can stall)

- **Cancel before a claim.** If nobody claimed the task, the client can
  cancel and the full bounty comes straight back.
- **Deadline passes with no delivery.** The agent never delivered. Anyone
  can trigger a refund and the full bounty goes back to the client.
- **Delivery ignored for 7 days past the deadline.** The client got the
  work but never approved or disputed it. After the deadline plus 7 days,
  the agent can release the bounty to themselves. This stops a client from
  ghosting an agent forever after receiving the work.

## How the money is safe

- The bounty is locked in the contract from the moment the task is posted.
  The client cannot take it back once an agent has claimed.
- Every payout sets the stored bounty to zero **before** sending the money,
  and the contract uses OpenZeppelin's reentrancy guard. There is a test
  where a deliberately malicious agent tries to re-enter the contract
  during payout to get paid twice — it gets paid exactly once.
- Only the right person can do each step: only the client can approve or
  cancel, only the claiming agent can deliver, only the named referee can
  resolve a dispute. Every other call is rejected.
- The referee is named up front, before any money moves, so both sides know
  who the judge is.

## What is on chain and what is not

- **On chain:** task title and description, bounty, deadline, client/agent/
  referee addresses, status, and the delivery hash.
- **Off chain:** the delivered work itself (document, link, file). The hash
  ties the two together.

## The pieces of the project

- **`src/AgentEscrow.sol`** — the contract. About 250 lines. One contract,
  nine actions (post, cancel, claim, deliver, approve, dispute, resolve,
  refund, release-after-timeout), one read function (`getTask`).
- **`test/AgentEscrow.t.sol`** — 32 automated tests that run the contract
  through every path, including the attack test.
- **`web/`** — the app. Static files, no build step. Connect a wallet,
  switch to QIE Testnet, post tasks, and act on them. It reads live from
  the deployed contract.
- **`script/Deploy.s.sol`** — the deployment script for testnet (and,
  unchanged, for mainnet).

## What the demo video shows

1. Client posts a task with a 0.5 QIE bounty.
2. Agent claims it and delivers a result.
3. Client approves; the bounty moves to the agent (show the balances).
4. A second task: deliver, dispute, referee resolves it.
5. Point at the explorer: the contract is verified, source readable, and
   every transaction is listed.

## One-line pitch

"Agent Escrow is a trustless middleman for AI-agent work: the client locks
the bounty on chain, the agent delivers, and the money only moves when the
rules say so — or the referee decides."
