# Agent Escrow — trustless escrow for AI-agent work on QIE

Hire an AI agent. Pay only when the work lands.

A client posts a task with a QIE bounty locked in escrow. An agent claims it
and delivers a result (only its hash is stored on chain). The client approves
and the bounty releases. If the two sides disagree, a referee named at
posting time decides who gets the bounty. Timeouts protect both sides: an
undelivered task refunds the client after the deadline, and a delivered task
the client ignores releases to the agent after a 7-day review window.

Built for **QIE Hackathon 3.0**, track **AI + Autonomous Agents**.
Solo entry by x3npai. Submit by **23:59 CET, 30 November 2026**.

## Live demo

- **App:** _(deploy the web app; see below)_
- **Contract (QIE Testnet, chain 1983):** _pending — needs test QIE from the faucet_
- **Explorer:** https://testnet.qie.digital

## How it works

```
Post (bounty locked) → Claim → Deliver (result hash) → Approve (agent paid)
                                              ↘ Dispute → Referee decides
Cancel before claim → full refund
Deadline passes with no delivery → anyone can refund the client
Delivery ignored 7 days past deadline → agent can release the bounty
```

See [HOW-IT-WORKS.md](HOW-IT-WORKS.md) for a plain-English walkthrough of
every part, and [YOUR-EDITS.md](YOUR-EDITS.md) for small edits you can make
yourself.

## Architecture

```
src/AgentEscrow.sol      The escrow contract (Solidity 0.8.24, OpenZeppelin ReentrancyGuard)
test/AgentEscrow.t.sol   32 Foundry tests: full lifecycle + edge cases + reentrancy attack
script/Deploy.s.sol      Testnet deployment script
web/                     Static web app (no build step)
  index.html             Post-task form, task list, filters, role-based actions
  app.js                 Wallet connect, chain switch, contract reads/writes (ethers v6)
  config.js              Contract address + QIE network config
  abi.js                 Contract ABI (generated from the build)
  ethers.umd.min.js      ethers v6.13.4, vendored so the app works without a CDN
  styles.css             Styling
```

Design decisions:

- **Result hash, not result data.** The delivered work lives off chain; only
  its `keccak256` hash is stored. Anyone can verify a delivery matches what
  was submitted, without bloating the chain.
- **Referee named at posting.** The client picks the referee, so both sides
  know who decides a dispute before any money moves. The referee cannot be
  the client and cannot claim the task.
- **Checks-effects-interactions + OpenZeppelin `ReentrancyGuard`.** All
  payouts zero the stored bounty before the external call. A reentrancy
  attack test (a malicious agent contract) proves a payout happens once.
- **QIE-pinned toolchain.** Foundry 1.9, solc 0.8.24, `evm_version =
  "paris"` (per the QIE team's quickstart), optimiser 200 runs.
  Primary testnet RPC is `https://rpc2testnet.qie.digital` — `rpc1testnet`
  times out from this machine; rpc2/rpc4/rpc5 all answer chain 1983.

## Run the tests

```bash
forge test
```

32 tests, all passing. Covers: posting validation (zero bounty, past
deadline, referee is the client, empty title), the full approve lifecycle,
cancel before/after claim, double claim, claim by client/referee, deliver by
a non-agent, deliver after the deadline, approve before delivery, dispute by
client/agent/non-party, resolve by non-referee, refund after/before the
deadline, release after the review window (and too early), and a reentrancy
attack on approval.

## Deploy to QIE Testnet

Prerequisites: Foundry 1.9 (`curl -L https://foundry.paradigm.xyz | bash &&
foundryup`), and 2 test QIE from https://www.qie.digital/faucet for the
deployer address (connect a wallet, paste the address, click Request Test
Coins; 2 test QIE per address per 24 h).

```bash
# 1. Create a fresh test-only deployer key (never reuse a mainnet key)
cast wallet new

# 2. Import it into Foundry's encrypted keystore
cast wallet import qie-testnet-dev --private-key <PASTE_KEY_ONCE>

# 3. Deploy + verify on the Blockscout explorer
forge script script/Deploy.s.sol \
  --rpc-url https://rpc2testnet.qie.digital --chain-id 1983 \
  --account qie-testnet-dev --broadcast \
  --verify --verifier blockscout \
  --verifier-url https://testnet.qie.digital/api/

# 4. Put the deployed address in web/config.js (CONTRACT_ADDRESS),
#    then serve web/ (any static host, e.g. Cloudflare Pages, output: web)
```

Never commit a private key, a `.env` file, or anything under
`~/.foundry/keystores/`. The test deployer key holds only faucet test QIE.

## Run the web app locally

```bash
cd web && python3 -m http.server 8123
# open http://localhost:8123 — connect MetaMask or QIE Wallet,
# switch to QIE Testnet (chain 1983) when prompted.
```

## Demo flow (for the video)

1. As the **client**: connect wallet, post a task (e.g. "Research the top 5
   AI note-taking tools", 0.5 QIE, deadline tomorrow), referee = a second
   address you control.
2. As the **agent** (second wallet): claim the task, deliver a result (paste
   the report text; its hash goes on chain).
3. As the **client**: approve — the bounty moves to the agent.
4. Show the dispute path on a second task: deliver, dispute, and as the
   **referee** resolve it either way.

## Mainnet

Mainnet deployment is required for the hackathon submission and is **not**
done yet. What it needs:

- A funded mainnet wallet (real QIE for gas). Deployment gas is measured on
  testnet first — see `script/Deploy.s.sol` output; the QIE team's example
  contract deployed for ~354k gas, and this contract is larger, so budget
  for roughly 1.5–2.5M gas at the live mainnet gas price.
- Deploy with `--rpc-url https://rpc1mainnet.qie.digital --chain-id 1990`
  and verify at https://mainnet.qie.digital/api/ (same Blockscout flags).
- Update `web/config.js` to the mainnet contract address and chain, and
  redeploy the web app.
- No code changes: the same contract and app work on both chains.

## Links

- QIE docs: https://docs.qie.digital
- QIE quickstart (Foundry on testnet): https://dev.to/qieteam/deploy-and-verify-your-first-solidity-contract-on-qie-testnet-in-15-minutes-2i7b
- Testnet explorer: https://testnet.qie.digital
- Testnet faucet: https://www.qie.digital/faucet
- Hackathon: https://hackathon.qie.digital

## Licence

MIT
