// AevumPay Protocol Frontend Engine
const QDAY_CHAIN_ID_HEX = "0xABE5"; // 44005
const QDAY_RPC_URL = "https://rpc-test.qday.info";
const QDAY_EXPLORER_URL = "https://explorer-test.qday.info/";
const TUSD8_ADDRESS = "0x456569838f1d43009A91ebA4263147Afd7233483";

let currentAccount = null;
let isSimulationMode = false;

// Mock in-memory state for instant interactive demo
const state = {
  payees: {
    "alice.qday": {
      address: "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6",
      legalName: "Alice Global Payments Inc.",
      status: "VERIFIED",
      metadataURI: "ipfs://bafy-alice-verified",
      registeredAt: "2026-11-09"
    },
    "rpc.node": {
      address: "0x456569838f1d43009A91ebA4263147Afd7233483",
      legalName: "QDay High-Throughput RPC Provider",
      status: "VERIFIED",
      metadataURI: "https://qday.info/rpc-provider.json",
      registeredAt: "2026-11-08"
    }
  },
  escrows: [
    {
      id: 1,
      payer: "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6",
      payee: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
      payeeName: "Bob International Logistics",
      amount: 1500,
      status: "FUNDED",
      deadline: "24h remaining",
      invoiceRef: "INV-2026-784",
      requireCop: true
    }
  ],
  streams: [
    {
      id: 1,
      payer: "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6",
      recipient: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
      title: "Senior Core Protocol Researcher",
      deposit: 3600,
      ratePerSecond: 1.0,
      startTime: Date.now() - 45000,
      claimed: 0,
      isPaused: false
    }
  ],
  agentVault: {
    agentAddress: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    perTxLimit: 50,
    dailyLimit: 200,
    spentToday: 45,
    enforceCop: true
  }
};

// Log event helper
function logEvent(type, message, txHash = null) {
  const feed = document.getElementById("activityFeed");
  const row = document.createElement("div");
  const time = new Date().toLocaleTimeString();
  const txLink = txHash ? ` <a href="${QDAY_EXPLORER_URL}tx/${txHash}" target="_blank" class="text-cyan-400 underline hover:text-cyan-300">[Tx: ${txHash.substring(0, 10)}...]</a>` : "";
  row.className = "text-slate-300";
  row.innerHTML = `<span class="text-slate-500">[${time}]</span> <span class="text-cyan-400 font-bold">[${type}]</span> ${message}${txLink}`;
  feed.insertBefore(row, feed.firstChild);
}

// Tab Switching
function switchTab(tabId) {
  document.querySelectorAll(".tab-panel").forEach(p => p.classList.add("hidden"));
  document.querySelectorAll(".tab-btn").forEach(b => {
    b.classList.remove("border-cyan-400", "text-cyan-400");
    b.classList.add("border-transparent", "text-slate-400");
  });

  const panel = document.getElementById(`panel-${tabId}`);
  const btn = document.getElementById(`tab-${tabId}`);
  if (panel && btn) {
    panel.classList.remove("hidden");
    btn.classList.add("border-cyan-400", "text-cyan-400");
    btn.classList.remove("border-transparent", "text-slate-400");
  }
}

// Wallet Connection & Network Handling
async function connectWallet() {
  if (window.ethereum) {
    try {
      const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
      currentAccount = accounts[0];
      updateWalletUI();
      await switchOrAddNetwork();
      logEvent("Wallet", `Connected wallet address ${currentAccount}`);
    } catch (err) {
      console.warn("Wallet connection rejected, using simulation mode:", err);
      enableSimulationMode();
    }
  } else {
    enableSimulationMode();
  }
}

function enableSimulationMode() {
  isSimulationMode = true;
  currentAccount = "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6";
  updateWalletUI();
  logEvent("Mode", "MetaMask not detected or declined. Enabled Interactive Testnet Simulation Mode with account " + currentAccount);
}

function updateWalletUI() {
  const btn = document.getElementById("connectWalletBtn");
  const text = document.getElementById("walletBtnText");
  const badge = document.getElementById("balanceBadge");

  text.textContent = `${currentAccount.substring(0, 6)}...${currentAccount.substring(38)}`;
  btn.classList.replace("from-cyan-500", "from-slate-800");
  btn.classList.replace("to-indigo-600", "to-slate-700");
  btn.classList.add("text-cyan-400", "border", "border-cyan-500/30");
  badge.classList.remove("hidden");
  badge.classList.add("flex");
}

async function switchOrAddNetwork() {
  if (!window.ethereum) return;
  try {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: QDAY_CHAIN_ID_HEX }]
    });
    logEvent("Network", "Switched to QDay Aevum Testnet (Chain ID 44005)");
  } catch (switchError) {
    if (switchError.code === 4902) {
      try {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: QDAY_CHAIN_ID_HEX,
            chainName: "QDay Aevum Testnet",
            nativeCurrency: { name: "tQDAY", symbol: "tQDAY", decimals: 18 },
            rpcUrls: [QDAY_RPC_URL],
            blockExplorerUrls: [QDAY_EXPLORER_URL]
          }]
        });
        logEvent("Network", "Added and connected QDay Aevum Testnet");
      } catch (addError) {
        console.error("Add network error:", addError);
      }
    }
  }
}

// 1. Confirmation of Payee (ERC-8004) Lookups
function lookupPayee() {
  const input = document.getElementById("copSearchInput").value.trim().toLowerCase();
  const res = document.getElementById("copResult");
  if (!input) return;

  res.classList.remove("hidden");
  let found = state.payees[input];
  if (!found) {
    for (const key in state.payees) {
      if (state.payees[key].address.toLowerCase() === input) {
        found = state.payees[key];
        break;
      }
    }
  }

  if (found) {
    res.innerHTML = `
      <div class="flex items-center justify-between border-b border-slate-800 pb-2">
        <span class="text-xs text-slate-400">Confirmation of Payee Status:</span>
        <span class="px-2 py-0.5 rounded text-xs font-bold bg-emerald-950 text-emerald-400 border border-emerald-800 flex items-center gap-1">
          <i class="fa-solid fa-circle-check"></i> ${found.status}
        </span>
      </div>
      <div class="grid grid-cols-2 gap-2 text-xs pt-1">
        <div><span class="text-slate-500">Legal Name:</span> <strong class="text-slate-200">${found.legalName}</strong></div>
        <div><span class="text-slate-500">Resolved Address:</span> <code class="text-cyan-400">${found.address.substring(0, 8)}...</code></div>
        <div class="col-span-2"><span class="text-slate-500">Metadata Proof:</span> <a href="#" class="text-indigo-400 underline">${found.metadataURI}</a></div>
      </div>
    `;
    logEvent("CoP Registry", `Verified payee record for "${input}": Status ${found.status}`);
  } else {
    res.innerHTML = `
      <div class="text-xs text-rose-400 flex items-center gap-2">
        <i class="fa-solid fa-triangle-exclamation"></i>
        <span>No verified ERC-8004 record found for "${input}". High risk of payment misdirection!</span>
      </div>
    `;
    logEvent("CoP Warning", `Unregistered payee query for "${input}"`);
  }
}

function registerPayee() {
  const identifier = document.getElementById("regIdentifier").value.trim().toLowerCase();
  const legalName = document.getElementById("regLegalName").value.trim();
  const metadata = document.getElementById("regMetadata").value.trim();

  if (!identifier || !legalName) {
    alert("Please enter identifier and legal name.");
    return;
  }

  const addr = currentAccount || "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6";
  state.payees[identifier] = {
    address: addr,
    legalName: legalName,
    status: "VERIFIED",
    metadataURI: metadata || "ipfs://bafy-default-proof",
    registeredAt: new Date().toISOString().split("T")[0]
  };

  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("ERC-8004", `Registered identifier "${identifier}" for ${addr}`, fakeTx);
  alert(`Payee identity "${identifier}" registered successfully on QDay Testnet!`);
  document.getElementById("copSearchInput").value = identifier;
  lookupPayee();
}

// 2. Escrows
function renderEscrows() {
  const container = document.getElementById("escrowList");
  container.innerHTML = "";

  state.escrows.forEach(e => {
    const card = document.createElement("div");
    card.className = "p-4 rounded-xl bg-slate-950 border border-slate-800 flex flex-col sm:flex-row sm:items-center justify-between gap-4";
    card.innerHTML = `
      <div class="space-y-1">
        <div class="flex items-center gap-2">
          <span class="text-sm font-bold text-white">Escrow #${e.id}: ${e.invoiceRef}</span>
          <span class="px-2 py-0.5 rounded text-[10px] font-bold ${e.status === 'RELEASED' ? 'bg-indigo-950 text-indigo-400 border border-indigo-800' : 'bg-emerald-950 text-emerald-400 border border-emerald-800'}">
            ${e.status}
          </span>
          ${e.requireCop ? '<span class="text-[10px] px-1.5 py-0.5 rounded bg-cyan-950 text-cyan-400 border border-cyan-800">CoP Verified</span>' : ''}
        </div>
        <div class="text-xs text-slate-400">
          Payee: <code class="text-slate-300">${e.payee.substring(0, 10)}...</code> | Amount: <strong class="text-emerald-400">${e.amount.toLocaleString()} tUSD8</strong>
        </div>
      </div>
      <div>
        ${e.status === 'FUNDED' ? `
          <button onclick="releaseEscrow(${e.id})" class="px-4 py-2 bg-emerald-500 hover:bg-emerald-400 text-slate-950 font-bold rounded-xl text-xs transition">
            Release Funds
          </button>
        ` : `
          <span class="text-xs text-slate-500 italic">Completed</span>
        `}
      </div>
    `;
    container.appendChild(card);
  });
}

function createEscrow() {
  const payee = document.getElementById("escrowPayee").value.trim() || "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
  const amount = parseFloat(document.getElementById("escrowAmount").value) || 500;
  const ref = document.getElementById("escrowRef").value.trim() || "INV-CUSTOM";
  const requireCop = document.getElementById("escrowRequireCop").checked;

  const newId = state.escrows.length + 1;
  state.escrows.unshift({
    id: newId,
    payer: currentAccount || "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6",
    payee: payee,
    amount: amount,
    status: "FUNDED",
    deadline: "24h remaining",
    invoiceRef: ref,
    requireCop: requireCop
  });

  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("Escrow", `Created escrow #${newId} for ${amount} tUSD8 -> ${payee}`, fakeTx);
  renderEscrows();
  alert(`Escrow #${newId} deposited and funded with ${amount} tUSD8!`);
}

function releaseEscrow(id) {
  const e = state.escrows.find(x => x.id === id);
  if (!e) return;
  e.status = "RELEASED";
  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("Escrow Release", `Released ${e.amount} tUSD8 to payee ${e.payee}`, fakeTx);
  renderEscrows();
}

// 3. Streaming Payroll
function renderStreams() {
  const container = document.getElementById("streamList");
  container.innerHTML = "";

  state.streams.forEach(s => {
    const elapsed = Math.floor((Date.now() - s.startTime) / 1000);
    const vested = Math.min(s.deposit, elapsed * s.ratePerSecond);
    const unvested = s.deposit - vested;
    const progress = Math.min(100, (vested / s.deposit) * 100);

    const card = document.createElement("div");
    card.className = "p-5 rounded-2xl bg-slate-950 border border-slate-800 space-y-3";
    card.innerHTML = `
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-sm font-bold text-white">${s.title}</h3>
          <div class="text-xs text-slate-400">Recipient: <code class="text-cyan-400">${s.recipient.substring(0, 10)}...</code></div>
        </div>
        <div class="text-right">
          <div class="text-lg font-black text-emerald-400 stream-ticker" id="stream-ticker-${s.id}">
            ${vested.toFixed(2)} tUSD8
          </div>
          <div class="text-[10px] text-slate-500">Rate: ${s.ratePerSecond} tUSD8 / sec</div>
        </div>
      </div>

      <div class="w-full bg-slate-900 rounded-full h-2.5 overflow-hidden">
        <div class="bg-gradient-to-r from-cyan-400 to-emerald-400 h-2.5 rounded-full transition-all duration-1000" style="width: ${progress}%"></div>
      </div>

      <div class="flex items-center justify-between text-xs text-slate-400 pt-1">
        <span>Total: ${s.deposit} tUSD8</span>
        <button onclick="claimStream(${s.id})" class="px-3 py-1.5 bg-cyan-500 hover:bg-cyan-400 text-slate-950 font-bold rounded-lg transition">
          Claim Vested Funds
        </button>
      </div>
    `;
    container.appendChild(card);
  });
}

function createStream() {
  const recipient = document.getElementById("streamRecipient").value.trim() || "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";
  const deposit = parseFloat(document.getElementById("streamDeposit").value) || 3600;
  const duration = parseFloat(document.getElementById("streamDuration").value) || 3600;
  const title = document.getElementById("streamTitle").value.trim() || "Core Engineer Stream";

  const newId = state.streams.length + 1;
  state.streams.push({
    id: newId,
    payer: currentAccount || "0xa554a9f6b26e6a418df3623b41e222e18a3b8da6",
    recipient: recipient,
    title: title,
    deposit: deposit,
    ratePerSecond: deposit / duration,
    startTime: Date.now(),
    claimed: 0,
    isPaused: false
  });

  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("Stream Created", `Streaming ${deposit} tUSD8 to ${recipient} (${(deposit/duration).toFixed(2)}/s)`, fakeTx);
  renderStreams();
  alert(`Payroll stream #${newId} initialized successfully!`);
}

function claimStream(id) {
  const s = state.streams.find(x => x.id === id);
  if (!s) return;
  const elapsed = Math.floor((Date.now() - s.startTime) / 1000);
  const vested = Math.min(s.deposit, elapsed * s.ratePerSecond);
  const claimable = vested - s.claimed;
  s.claimed = vested;
  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("Stream Claim", `Claimed ${claimable.toFixed(2)} tUSD8 from Stream #${id}`, fakeTx);
  alert(`Claimed ${claimable.toFixed(2)} tUSD8 directly to wallet!`);
}

// 4. Autonomous AI Agent Vault
function configureAgent() {
  const addr = document.getElementById("agentAddress").value.trim() || "0x90F79bf6EB2c4f870365E785982E1f101E93b906";
  const perTx = parseFloat(document.getElementById("agentPerTx").value) || 50;
  const daily = parseFloat(document.getElementById("agentDaily").value) || 200;
  const enforceCop = document.getElementById("agentRequireCop").checked;

  state.agentVault = {
    agentAddress: addr,
    perTxLimit: perTx,
    dailyLimit: daily,
    spentToday: 0,
    enforceCop: enforceCop
  };

  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("AI Agent Policy", `Authorized agent ${addr.substring(0, 8)}... (Max: ${perTx}/tx, ${daily}/day, CoP: ${enforceCop})`, fakeTx);
  alert("AI Agent session policy configured and bounded on-chain!");
}

function executeAgentSim() {
  const recipient = document.getElementById("simMerchant").value.trim() || "rpc.node";
  const amount = parseFloat(document.getElementById("simAmount").value) || 25;
  const purpose = document.getElementById("simPurpose").value.trim() || "LLM Inference Payment";

  const v = state.agentVault;

  // Validation
  if (amount > v.perTxLimit) {
    alert(`Autonomous execution rejected: Amount (${amount} tUSD8) exceeds per-tx session limit (${v.perTxLimit} tUSD8)!`);
    logEvent("Agent Rejection", `Payment of ${amount} tUSD8 exceeded per-tx bound`);
    return;
  }

  if (v.spentToday + amount > v.dailyLimit) {
    alert(`Autonomous execution rejected: Exceeds 24h rolling budget quota (${v.dailyLimit} tUSD8)!`);
    logEvent("Agent Rejection", `Payment of ${amount} tUSD8 exceeded 24h rolling budget`);
    return;
  }

  if (v.enforceCop) {
    const isVerified = state.payees[recipient] && state.payees[recipient].status === "VERIFIED";
    if (!isVerified) {
      alert(`Autonomous execution blocked: Recipient "${recipient}" is not verified under ERC-8004 Confirmation of Payee!`);
      logEvent("Agent Security Block", `Intercepted payment to unverified recipient "${recipient}"`);
      return;
    }
  }

  v.spentToday += amount;
  const fakeTx = "0x" + Array.from({length: 64}, () => Math.floor(Math.random()*16).toString(16)).join("");
  logEvent("Autonomous Execution", `Agent settled ${amount} tUSD8 to "${recipient}" for: "${purpose}"`, fakeTx);
  alert(`[Autonomous AI Agent Success]\nSettled: ${amount} tUSD8\nRecipient: ${recipient}\nPurpose: ${purpose}\nRemaining daily budget: ${v.dailyLimit - v.spentToday} tUSD8`);
}

// Global Ticker Loop for streams
setInterval(() => {
  state.streams.forEach(s => {
    const el = document.getElementById(`stream-ticker-${s.id}`);
    if (el) {
      const elapsed = Math.floor((Date.now() - s.startTime) / 1000);
      const vested = Math.min(s.deposit, elapsed * s.ratePerSecond);
      el.textContent = `${vested.toFixed(2)} tUSD8`;
    }
  });
}, 1000);

// Initialize UI
window.addEventListener("DOMContentLoaded", () => {
  document.getElementById("connectWalletBtn").addEventListener("click", connectWallet);
  document.getElementById("addNetworkBtn").addEventListener("click", switchOrAddNetwork);
  renderEscrows();
  renderStreams();
});
