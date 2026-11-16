// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";

/// @notice Deploy AgentEscrow to QIE Testnet (chain 1983).
/// @dev Fund the deployer first: claim 2 test QIE at
/// https://www.qie.digital/faucet for the deployer address, then run:
///   CAST_UNSAFE_PASSWORD=$(cat ~/.foundry/qie-testnet-dev.pw) \
///   forge script script/Deploy.s.sol \
///     --rpc-url https://rpc2testnet.qie.digital --chain-id 1983 \
///     --account qie-testnet-dev --broadcast \
///     --verify --verifier blockscout \
///     --verifier-url https://testnet.qie.digital/api/
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        AgentEscrow escrow = new AgentEscrow();
        console.log("AgentEscrow deployed to:", address(escrow));
        vm.stopBroadcast();
    }
}
