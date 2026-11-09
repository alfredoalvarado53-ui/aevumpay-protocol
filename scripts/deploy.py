import os
import json
import sys
from web3 import Web3
from eth_account import Account

QDAY_TESTNET_RPC = "https://rpc-test.qday.info"
QDAY_CHAIN_ID = 44005
TUSD8_TESTNET_ADDRESS = "0x456569838f1d43009A91ebA4263147Afd7233483"

def deploy():
    print("==================================================")
    print("  AevumPay Protocol - QDay Aevum Testnet Deployer ")
    print("==================================================")

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    artifacts_dir = os.path.join(base_dir, "artifacts")
    deployments_dir = os.path.join(base_dir, "deployments")
    os.makedirs(deployments_dir, exist_ok=True)

    w3 = Web3(Web3.HTTPProvider(QDAY_TESTNET_RPC))
    if not w3.is_connected():
        print(f"[-] Error: Could not connect to QDay RPC at {QDAY_TESTNET_RPC}")
        sys.exit(1)

    print(f"[+] Connected to QDay Aevum Testnet (Chain ID: {QDAY_CHAIN_ID})")
    print(f"[+] Current block number: {w3.eth.block_number}")

    private_key = os.environ.get("PRIVATE_KEY")
    if not private_key:
        print("[!] Note: PRIVATE_KEY environment variable is not set.")
        print("    To deploy live to QDay Testnet, export PRIVATE_KEY=0x... and re-run.")
        print("    Generating simulation report with target network addresses...")
        
        simulated_record = {
            "network": "QDay Aevum Testnet",
            "chainId": QDAY_CHAIN_ID,
            "rpcUrl": QDAY_TESTNET_RPC,
            "explorerUrl": "https://explorer-test.qday.info/",
            "contracts": {
                "tUSD8": TUSD8_TESTNET_ADDRESS,
                "ERC8004Registry": "Pending Live Faucet Gas",
                "AevumPayEscrow": "Pending Live Faucet Gas",
                "AevumStreamPayroll": "Pending Live Faucet Gas",
                "AevumAgentVault": "Pending Live Faucet Gas"
            },
            "status": "ready_for_broadcast"
        }
        with open(os.path.join(deployments_dir, "qday_testnet.json"), "w", encoding="utf-8") as f:
            json.dump(simulated_record, f, indent=2)
        print(f"[+] Configuration written to deployments/qday_testnet.json")
        return

    account = Account.from_key(private_key)
    deployer = account.address
    balance = w3.eth.get_balance(deployer)
    print(f"[+] Deployer Address: {deployer}")
    print(f"[+] Deployer tQDAY Balance: {w3.from_wei(balance, 'ether')} tQDAY")

    if balance == 0:
        print("[-] Insufficient gas funds. Please request tQDAY from https://faucet.qday.info/en")
        sys.exit(1)

    def send_deploy(contract_name, constructor_args=None):
        with open(os.path.join(artifacts_dir, f"{contract_name}.json"), "r", encoding="utf-8") as f:
            art = json.load(f)
        
        Contract = w3.eth.contract(abi=art["abi"], bytecode=art["bytecode"])
        args = constructor_args or []
        nonce = w3.eth.get_transaction_count(deployer)
        gas_price = w3.eth.gas_price

        construct_txn = Contract.constructor(*args).build_transaction({
            "from": deployer,
            "nonce": nonce,
            "gasPrice": gas_price,
            "chainId": QDAY_CHAIN_ID
        })
        signed = account.sign_transaction(construct_txn)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"[*] Deploying {contract_name}... Tx: {tx_hash.hex()}")
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
        print(f"[+] {contract_name} deployed at: {receipt.contractAddress}")
        return receipt.contractAddress

    # 1. Deploy ERC8004Registry
    erc8004_addr = send_deploy("ERC8004Registry")

    # 2. Deploy AevumPayEscrow
    escrow_addr = send_deploy("AevumPayEscrow", [erc8004_addr, deployer])

    # 3. Deploy AevumStreamPayroll
    stream_addr = send_deploy("AevumStreamPayroll")

    # 4. Deploy AevumAgentVault
    vault_addr = send_deploy("AevumAgentVault", [erc8004_addr])

    deployment_record = {
        "network": "QDay Aevum Testnet",
        "chainId": QDAY_CHAIN_ID,
        "rpcUrl": QDAY_TESTNET_RPC,
        "explorerUrl": "https://explorer-test.qday.info/",
        "contracts": {
            "tUSD8": TUSD8_TESTNET_ADDRESS,
            "ERC8004Registry": erc8004_addr,
            "AevumPayEscrow": escrow_addr,
            "AevumStreamPayroll": stream_addr,
            "AevumAgentVault": vault_addr
        },
        "deployer": deployer,
        "status": "deployed"
    }

    with open(os.path.join(deployments_dir, "qday_testnet.json"), "w", encoding="utf-8") as f:
        json.dump(deployment_record, f, indent=2)

    print("\n[+] All contracts successfully deployed and recorded in deployments/qday_testnet.json!")

if __name__ == "__main__":
    deploy()
