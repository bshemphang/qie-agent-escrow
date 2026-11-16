// Agent Escrow deployment config.
// Set CONTRACT_ADDRESS after deploying to QIE Testnet (chain 1983).
// The app reads live from this contract; leave the address empty and the
// page shows a "not deployed yet" notice instead of failing.
window.AGENT_ESCROW_CONFIG = {
  CONTRACT_ADDRESS: "",
  CHAIN_ID: 1983,
  CHAIN_ID_HEX: "0x7bf",
  CHAIN_NAME: "QIE Testnet",
  RPC_URL: "https://rpc2testnet.qie.digital",
  EXPLORER_URL: "https://testnet.qie.digital",
  CURRENCY: "QIE"
};
