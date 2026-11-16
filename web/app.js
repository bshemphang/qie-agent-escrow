// Agent Escrow — front end for QIE Testnet (chain 1983).
// Reads live from the deployed contract; writes go through the user's wallet
// (MetaMask or QIE Wallet, standard EIP-1193 provider).
(function () {
  "use strict";

  if (typeof ethers === "undefined") {
    document.addEventListener("DOMContentLoaded", function () {
      var el = document.getElementById("appError");
      el.textContent = "Could not load the ethers library (web/ethers.umd.min.js). Check your connection and reload.";
      el.classList.remove("hidden");
    });
    return;
  }

  var CFG = window.AGENT_ESCROW_CONFIG;
  var ABI = window.AGENT_ESCROW_ABI;
  var REVIEW_WINDOW_S = 7 * 24 * 3600;
  var STATUS_NAMES = ["Open", "Claimed", "Delivered", "Completed", "Disputed", "Resolved", "Cancelled", "Refunded"];
  var FINISHED = [3, 5, 6, 7]; // Completed, Resolved, Cancelled, Refunded

  var readProvider = new ethers.JsonRpcProvider(CFG.RPC_URL);
  var readContract = CFG.CONTRACT_ADDRESS
    ? new ethers.Contract(CFG.CONTRACT_ADDRESS, ABI, readProvider)
    : null;

  var account = null; // connected wallet address (checksummed) or null
  var browserProvider = null;
  var tasks = [];
  var activeFilter = "all";

  var $ = function (id) { return document.getElementById(id); };

  function shortAddr(a) {
    if (!a || a === "0x0000000000000000000000000000000000000000") return "—";
    return a.slice(0, 6) + "…" + a.slice(-4);
  }

  function showError(msg) {
    var el = $("appError");
    el.textContent = msg;
    el.classList.remove("hidden");
  }

  function clearError() { $("appError").classList.add("hidden"); }

  function fmtQie(wei) {
    return ethers.formatEther(wei) + " QIE";
  }

  function fmtDeadline(ts) {
    var d = new Date(Number(ts) * 1000);
    var now = Date.now();
    var diff = d.getTime() - now;
    var date = d.toLocaleString(undefined, {
      month: "short", day: "numeric", hour: "2-digit", minute: "2-digit"
    });
    if (diff <= 0) return date + " (passed)";
    var hours = Math.floor(diff / 3600000);
    if (hours < 24) return date + " (in " + hours + "h)";
    return date + " (in " + Math.floor(hours / 24) + "d)";
  }

  function setStatus(msg, kind) {
    var el = $("postStatus");
    el.textContent = msg;
    el.className = "form-status" + (kind ? " " + kind : "");
  }

  // ---- wallet ----

  function updateConnectUI() {
    var btn = $("connectBtn");
    var label = $("accountLabel");
    var badge = $("networkBadge");
    if (account) {
      btn.classList.add("hidden");
      label.textContent = shortAddr(account);
      label.classList.remove("hidden");
      badge.textContent = CFG.CHAIN_NAME + " · Chain " + CFG.CHAIN_ID;
      badge.classList.remove("warn");
    } else {
      btn.classList.remove("hidden");
      label.classList.add("hidden");
      btn.textContent = "Connect wallet";
    }
  }

  async function switchNetwork() {
    try {
      await window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: CFG.CHAIN_ID_HEX }]
      });
      return true;
    } catch (err) {
      if (err && err.code === 4902) {
        try {
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: CFG.CHAIN_ID_HEX,
              chainName: CFG.CHAIN_NAME,
              nativeCurrency: { name: "QIE", symbol: "QIE", decimals: 18 },
              rpcUrls: [CFG.RPC_URL],
              blockExplorerUrls: [CFG.EXPLORER_URL]
            }]
          });
          return true;
        } catch (e2) {
          showError("Could not add QIE Testnet to your wallet: " + (e2.message || e2));
          return false;
        }
      }
      showError("Please switch your wallet to QIE Testnet (chain 1983).");
      return false;
    }
  }

  async function connectWallet() {
    clearError();
    if (!window.ethereum) {
      showError("No wallet found. Install MetaMask or QIE Wallet, then try again.");
      return;
    }
    try {
      browserProvider = new ethers.BrowserProvider(window.ethereum);
      var accounts = await browserProvider.send("eth_requestAccounts", []);
      account = ethers.getAddress(accounts[0]);
      var net = await browserProvider.getNetwork();
      if (Number(net.chainId) !== CFG.CHAIN_ID) {
        var ok = await switchNetwork();
        if (!ok) { account = null; updateConnectUI(); return; }
        browserProvider = new ethers.BrowserProvider(window.ethereum);
      }
      updateConnectUI();
      renderTasks();
    } catch (err) {
      showError("Wallet connection failed: " + (err.message || err));
    }
  }

  function signerContract() {
    if (!browserProvider || !account) return null;
    return browserProvider.getSigner().then(function (signer) {
      return new ethers.Contract(CFG.CONTRACT_ADDRESS, ABI, signer);
    });
  }

  async function sendTx(promiseFn, statusEl) {
    try {
      var contract = await signerContract();
      if (!contract) { showError("Connect your wallet first."); return; }
      var tx = await promiseFn(contract);
      if (statusEl) { statusEl.textContent = "Transaction sent: " + tx.hash + " — waiting for confirmation…"; }
      await tx.wait();
      await loadTasks();
    } catch (err) {
      var msg = (err && err.message) || String(err);
      if (msg.indexOf("user rejected") !== -1 || (err && err.code === 4001)) {
        if (statusEl) statusEl.textContent = "Transaction rejected in wallet.";
      } else {
        showError("Transaction failed: " + msg.slice(0, 300));
      }
      throw err;
    }
  }

  // ---- tasks ----

  async function loadTasks() {
    if (!readContract) return;
    try {
      var count = await readContract.taskCount();
      var loaded = [];
      for (var i = 0; i < Number(count); i++) {
        var t = await readContract.getTask(i);
        loaded.push({
          id: i,
          client: t.client,
          agent: t.agent,
          referee: t.referee,
          bounty: t.bounty,
          deadline: t.deadline,
          deliveryHash: t.deliveryHash,
          title: t.title,
          description: t.description,
          status: Number(t.status)
        });
      }
      tasks = loaded.reverse(); // newest first
      renderTasks();
    } catch (err) {
      showError("Could not read tasks from the contract: " + (err.message || err));
    }
  }

  function visibleTasks() {
    if (activeFilter === "all") return tasks;
    if (activeFilter === "done") return tasks.filter(function (t) { return FINISHED.indexOf(t.status) !== -1; });
    var s = Number(activeFilter);
    return tasks.filter(function (t) { return t.status === s; });
  }

  function isClient(t) { return account && account.toLowerCase() === t.client.toLowerCase(); }
  function isAgent(t) { return account && account.toLowerCase() === t.agent.toLowerCase(); }
  function isReferee(t) { return account && account.toLowerCase() === t.referee.toLowerCase(); }

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function actionButtons(t) {
    var now = Math.floor(Date.now() / 1000);
    var out = [];
    if (!account) {
      out.push('<p class="hint">Connect your wallet to act on this task.</p>');
      return out.join("");
    }
    if (t.status === 0) { // Open
      if (isClient(t)) {
        out.push('<button class="btn btn-danger btn-sm" data-act="cancel" data-id="' + t.id + '">Cancel and refund</button>');
      } else if (!isReferee(t)) {
        out.push('<button class="btn btn-primary btn-sm" data-act="claim" data-id="' + t.id + '">Claim this task</button>');
      } else {
        out.push('<p class="hint">You are the referee for this task, so you cannot claim it.</p>');
      }
    } else if (t.status === 1) { // Claimed
      if (isAgent(t)) {
        out.push('<button class="btn btn-primary btn-sm" data-act="deliver" data-id="' + t.id + '">Deliver result</button>');
      } else {
        out.push('<p class="hint">Claimed by ' + esc(shortAddr(t.agent)) + '. Waiting for delivery.</p>');
      }
      if (now > Number(t.deadline)) {
        out.push('<button class="btn btn-ghost btn-sm" data-act="refund" data-id="' + t.id + '">Refund client (deadline passed)</button>');
      }
    } else if (t.status === 2) { // Delivered
      if (isClient(t)) {
        out.push('<button class="btn btn-primary btn-sm" data-act="approve" data-id="' + t.id + '">Approve and pay agent</button>');
      }
      if (isClient(t) || isAgent(t)) {
        out.push('<button class="btn btn-ghost btn-sm" data-act="dispute" data-id="' + t.id + '">Dispute</button>');
      }
      if (isAgent(t) && now > Number(t.deadline) + REVIEW_WINDOW_S) {
        out.push('<button class="btn btn-ghost btn-sm" data-act="release" data-id="' + t.id + '">Release bounty (review window passed)</button>');
      }
      if (!isClient(t) && !isAgent(t)) {
        out.push('<p class="hint">Delivered. Waiting for the client to approve or dispute.</p>');
      }
    } else if (t.status === 4) { // Disputed
      if (isReferee(t)) {
        out.push('<button class="btn btn-primary btn-sm" data-act="resolve-agent" data-id="' + t.id + '">Resolve: pay agent</button>');
        out.push('<button class="btn btn-ghost btn-sm" data-act="resolve-client" data-id="' + t.id + '">Resolve: refund client</button>');
      } else {
        out.push('<p class="hint">Disputed. Waiting for the referee ' + esc(shortAddr(t.referee)) + ' to decide.</p>');
      }
    }
    return out.join("");
  }

  function renderTasks() {
    var list = $("taskList");
    var shown = visibleTasks();
    $("tasksEmpty").classList.toggle("hidden", shown.length > 0 || tasks.length > 0);
    if (tasks.length === 0) { list.innerHTML = ""; return; }
    if (shown.length === 0) {
      list.innerHTML = '<p class="empty">No tasks match this filter.</p>';
      return;
    }
    list.innerHTML = shown.map(function (t) {
      var hash = t.deliveryHash === "0x0000000000000000000000000000000000000000000000000000000000000000"
        ? "—" : t.deliveryHash.slice(0, 18) + "…";
      // The contract zeroes the stored bounty once it is paid out, so for
      // finished tasks show what happened instead of "0.0 QIE".
      var bountyText = fmtQie(t.bounty);
      if (t.status === 3 || t.status === 5) bountyText = "Paid out";
      if (t.status === 6 || t.status === 7) bountyText = "Refunded";
      return '<article class="task">' +
        '<div class="task-top"><h3>' + esc(t.title) + '</h3>' +
        '<span class="status status-' + t.status + '">' + STATUS_NAMES[t.status] + '</span></div>' +
        '<p class="task-desc">' + esc(t.description) + '</p>' +
        '<dl class="task-meta">' +
        '<div><dt>Bounty</dt><dd>' + bountyText + '</dd></div>' +
        '<div><dt>Deadline</dt><dd>' + fmtDeadline(t.deadline) + '</dd></div>' +
        '<div><dt>Client</dt><dd>' + esc(shortAddr(t.client)) + '</dd></div>' +
        '<div><dt>Agent</dt><dd>' + esc(shortAddr(t.agent)) + '</dd></div>' +
        '<div><dt>Referee</dt><dd>' + esc(shortAddr(t.referee)) + '</dd></div>' +
        '<div><dt>Result hash</dt><dd>' + esc(hash) + '</dd></div>' +
        '</dl>' +
        '<div class="task-actions">' + actionButtons(t) + '</div>' +
        '</article>';
    }).join("");
  }

  // ---- post form ----

  async function onPostSubmit(ev) {
    ev.preventDefault();
    clearError();
    if (!readContract) { showError("The contract is not deployed yet."); return; }
    if (!account) { showError("Connect your wallet first."); return; }

    var title = $("title").value.trim();
    var description = $("description").value.trim();
    var bountyStr = $("bounty").value;
    var deadlineStr = $("deadline").value;
    var referee = $("referee").value.trim();

    if (!title || !description || !bountyStr || !deadlineStr || !referee) {
      setStatus("Fill in every field.", "error");
      return;
    }
    var deadline = Math.floor(new Date(deadlineStr).getTime() / 1000);
    if (deadline <= Math.floor(Date.now() / 1000)) {
      setStatus("The deadline must be in the future.", "error");
      return;
    }
    var refereeOk = false;
    try { refereeOk = ethers.isAddress(referee); } catch (e) { refereeOk = false; }
    if (!refereeOk) { setStatus("The referee address is not valid.", "error"); return; }
    if (referee.toLowerCase() === account.toLowerCase()) {
      setStatus("The referee cannot be you. Pick a neutral third party.", "error");
      return;
    }

    var postBtn = $("postBtn");
    postBtn.disabled = true;
    setStatus("Posting to the chain… confirm in your wallet.");
    try {
      var bounty = ethers.parseEther(bountyStr);
      await sendTx(function (c) {
        return c.postTask(referee, title, description, deadline, { value: bounty });
      }, $("postStatus"));
      setStatus("Task posted and bounty locked.", "ok");
      $("postForm").reset();
    } catch (err) {
      setStatus("Posting failed. See the error above.", "error");
    } finally {
      postBtn.disabled = false;
    }
  }

  // ---- task actions (event delegation) ----

  async function onTaskAction(ev) {
    var btn = ev.target.closest("[data-act]");
    if (!btn) return;
    clearError();
    var act = btn.getAttribute("data-act");
    var id = Number(btn.getAttribute("data-id"));
    var statusEl = null;

    try {
      if (act === "claim") {
        await sendTx(function (c) { return c.claimTask(id); }, statusEl);
      } else if (act === "cancel") {
        if (!confirm("Cancel this task? The bounty returns to you.")) return;
        await sendTx(function (c) { return c.cancelTask(id); }, statusEl);
      } else if (act === "deliver") {
        var text = prompt("Paste or type your delivered result (a link, a summary, or the full text). Only its hash is stored on chain:");
        if (text === null || text.trim() === "") return;
        var hash = ethers.keccak256(ethers.toUtf8Bytes(text));
        if (!confirm("This delivery hash will be stored on chain:\n" + hash + "\n\nContinue?")) return;
        await sendTx(function (c) { return c.deliverTask(id, hash); }, statusEl);
      } else if (act === "approve") {
        if (!confirm("Approve this delivery? The full bounty goes to the agent.")) return;
        await sendTx(function (c) { return c.approveTask(id); }, statusEl);
      } else if (act === "dispute") {
        if (!confirm("Raise a dispute? The referee will decide who gets the bounty.")) return;
        await sendTx(function (c) { return c.disputeTask(id); }, statusEl);
      } else if (act === "resolve-agent" || act === "resolve-client") {
        var payAgent = act === "resolve-agent";
        if (!confirm(payAgent ? "Resolve in favour of the agent? The bounty goes to the agent." : "Resolve in favour of the client? The bounty is refunded.")) return;
        await sendTx(function (c) { return c.resolveDispute(id, payAgent); }, statusEl);
      } else if (act === "refund") {
        await sendTx(function (c) { return c.refundTask(id); }, statusEl);
      } else if (act === "release") {
        await sendTx(function (c) { return c.releaseAfterTimeout(id); }, statusEl);
      }
    } catch (err) {
      // sendTx already surfaced the error; nothing more to do here.
    }
  }

  // ---- boot ----

  function init() {
    var notice = $("deployNotice");
    var link = $("contractLink");
    if (!CFG.CONTRACT_ADDRESS) {
      notice.textContent = "The escrow contract is not deployed yet. Deploy it to QIE Testnet, then set CONTRACT_ADDRESS in web/config.js.";
      notice.classList.remove("hidden");
      link.textContent = "Contract: not deployed";
    } else {
      link.innerHTML = 'Contract: <a href="' + CFG.EXPLORER_URL + "/address/" + CFG.CONTRACT_ADDRESS + '" target="_blank" rel="noopener">' + shortAddr(CFG.CONTRACT_ADDRESS) + "</a>";
      loadTasks();
      setInterval(loadTasks, 15000);
    }
    renderTasks(); // shows the "No tasks yet" empty state pre-deploy

    $("connectBtn").addEventListener("click", connectWallet);
    $("postForm").addEventListener("submit", onPostSubmit);
    $("taskList").addEventListener("click", onTaskAction);
    $("refreshBtn").addEventListener("click", loadTasks);
    $("filters").addEventListener("click", function (ev) {
      var b = ev.target.closest(".filter");
      if (!b) return;
      document.querySelectorAll(".filter").forEach(function (f) { f.classList.remove("active"); });
      b.classList.add("active");
      activeFilter = b.getAttribute("data-filter");
      renderTasks();
    });

    if (window.ethereum) {
      window.ethereum.on("accountsChanged", function (accs) {
        account = accs && accs.length ? ethers.getAddress(accs[0]) : null;
        updateConnectUI();
        renderTasks();
      });
      window.ethereum.on("chainChanged", function () { window.location.reload(); });
      // Reconnect silently if the wallet is already authorised.
      browserProvider = new ethers.BrowserProvider(window.ethereum);
      browserProvider.listAccounts().then(function (accs) {
        if (accs && accs.length) {
          account = ethers.getAddress(accs[0].address);
          browserProvider.getNetwork().then(function (net) {
            if (Number(net.chainId) !== CFG.CHAIN_ID) {
              $("networkBadge").textContent = "Wrong network — switch to QIE Testnet";
              $("networkBadge").classList.add("warn");
            }
            updateConnectUI();
            renderTasks();
          });
        }
      }).catch(function () { /* wallet locked; user connects manually */ });
    }
    updateConnectUI();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
