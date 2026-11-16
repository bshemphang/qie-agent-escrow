# Small edits you can make yourself

These are safe, small changes that make the project visibly yours. Each one
is a single edit in one file. Make them, commit them as yourself, and they
count as your own contribution to the repo (which matters for the hackathon's
anti-abuse rule — the project must be demonstrably built by you, not just by
an AI agent).

## 1. Change the review window (contract)

**File:** `src/AgentEscrow.sol`
**Line:** `uint256 public constant REVIEW_WINDOW = 7 days;`

Change `7 days` to `3 days` or `14 days`. This is how long a client has to
review a delivery before the agent can release the bounty themselves.
After changing it, run `forge test` — all 32 tests should still pass (the
tests read the value from the contract, they do not hard-code 7 days).

## 2. Rewrite the hero text (web app)

**File:** `web/index.html`
**Lines:** the `<h1>` and the `<p class="lede">` under it.

Write the headline in your own words. Example: "Pay an AI agent only when
the work is done." Keep it to one short sentence, and keep the paragraph
under it to two sentences.

## 3. Change the accent colour (web app)

**File:** `web/styles.css`
**Lines:** `--accent: #5b4bc4;` and `--accent-dark: #463a9e;` at the top.

Pick any colour you like (e.g. `#0f766e` for teal, `#b45309` for amber).
Change both lines so the buttons and highlights still match. Reload the
page to see it.

## 4. Add a second example task title (web app)

**File:** `web/index.html`
**Line:** the `placeholder` of the Title input (`e.g. Research the top 5 AI
note-taking tools`).

Replace it with a task you would actually post, e.g. "Summarise 10 papers
on small language models into a one-page brief". This is copy only; nothing
else changes.

## 5. Rename the project in the footer (web app)

**File:** `web/index.html`
**Line:** the footer text `Agent Escrow · QIE Hackathon 3.0 · AI +
Autonomous Agents track`.

If you want a different project name, change it here and in the `<title>`
at the top of the file. Keep "QIE Hackathon 3.0" in the footer so judges
can see the context.

---

How to commit one of these:

```bash
cd ~/workspace/qie-hackathon/qie-agent-escrow
git add <file you edited>
git commit -m "Tweak: <what you changed, in your words>"
git push
```

Do not commit anything under `out/`, `cache/`, or any file with a private
key in it. If `git status` shows a file you do not recognise, ask before
adding it.
