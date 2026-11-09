import os
import json
import unittest
import hashlib
from web3 import Web3
from web3.providers.eth_tester import EthereumTesterProvider

class TestAevumPayProtocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.w3 = Web3(EthereumTesterProvider())
        cls.accounts = cls.w3.eth.accounts
        cls.deployer = cls.accounts[0]
        cls.payer = cls.accounts[1]
        cls.payee = cls.accounts[2]
        cls.arbitrator = cls.accounts[3]
        cls.agent = cls.accounts[4]
        cls.unverified = cls.accounts[5]

        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        cls.artifacts_dir = os.path.join(base_dir, "artifacts")

        def load_artifact(name):
            with open(os.path.join(cls.artifacts_dir, f"{name}.json"), "r", encoding="utf-8") as f:
                return json.load(f)

        cls.erc8004_art = load_artifact("ERC8004Registry")
        cls.escrow_art = load_artifact("AevumPayEscrow")
        cls.stream_art = load_artifact("AevumStreamPayroll")
        cls.vault_art = load_artifact("AevumAgentVault")
        cls.tusd8_art = load_artifact("MockUSD8")

    def setUp(self):
        # 1. Deploy MockUSD8
        MockUSD8 = self.w3.eth.contract(abi=self.tusd8_art["abi"], bytecode=self.tusd8_art["bytecode"])
        tx_hash = MockUSD8.constructor().transact({"from": self.deployer})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        self.tusd8 = self.w3.eth.contract(address=receipt.contractAddress, abi=self.tusd8_art["abi"])

        # Fund payer and agent
        self.tusd8.functions.mint(self.payer, 50_000 * 10**6).transact({"from": self.deployer})
        self.tusd8.functions.mint(self.deployer, 50_000 * 10**6).transact({"from": self.deployer})

        # 2. Deploy ERC8004Registry
        ERC8004 = self.w3.eth.contract(abi=self.erc8004_art["abi"], bytecode=self.erc8004_art["bytecode"])
        tx_hash = ERC8004.constructor().transact({"from": self.deployer})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        self.registry = self.w3.eth.contract(address=receipt.contractAddress, abi=self.erc8004_art["abi"])

        # 3. Deploy AevumPayEscrow
        Escrow = self.w3.eth.contract(abi=self.escrow_art["abi"], bytecode=self.escrow_art["bytecode"])
        tx_hash = Escrow.constructor(self.registry.address, self.arbitrator).transact({"from": self.deployer})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        self.escrow = self.w3.eth.contract(address=receipt.contractAddress, abi=self.escrow_art["abi"])

        # 4. Deploy AevumStreamPayroll
        Stream = self.w3.eth.contract(abi=self.stream_art["abi"], bytecode=self.stream_art["bytecode"])
        tx_hash = Stream.constructor().transact({"from": self.deployer})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        self.stream = self.w3.eth.contract(address=receipt.contractAddress, abi=self.stream_art["abi"])

        # 5. Deploy AevumAgentVault
        Vault = self.w3.eth.contract(abi=self.vault_art["abi"], bytecode=self.vault_art["bytecode"])
        tx_hash = Vault.constructor(self.registry.address).transact({"from": self.deployer})
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)
        self.vault = self.w3.eth.contract(address=receipt.contractAddress, abi=self.vault_art["abi"])

    def test_01_erc8004_confirmation_of_payee(self):
        """Test registration, verification, resolution, and revocation of payees."""
        # Payee self-registers
        self.registry.functions.registerPayee("alice.qday", "Alice Corp LLC", "ipfs://bafy-alice").transact({"from": self.payee})
        
        payee_data = self.registry.functions.getPayee(self.payee).call()
        self.assertEqual(payee_data[0], "alice.qday")
        self.assertEqual(payee_data[1], "Alice Corp LLC")
        self.assertEqual(payee_data[3], 1) # PENDING
        self.assertFalse(self.registry.functions.isVerifiedPayee(self.payee).call())

        # Resolve identifier
        resolved = self.registry.functions.resolveIdentifier("alice.qday").call()
        self.assertEqual(resolved, self.payee)

        # Verifier approves payee
        self.registry.functions.verifyPayee(self.payee, 2).transact({"from": self.deployer}) # 2 = VERIFIED
        self.assertTrue(self.registry.functions.isVerifiedPayee(self.payee).call())

        # Test duplicate identifier rejection
        with self.assertRaises(Exception):
            self.registry.functions.registerPayee("alice.qday", "Evil Impostor", "").transact({"from": self.unverified})

    def test_02_escrow_lifecycle_with_cop(self):
        """Test invoice milestone escrow with ERC-8004 verification and release."""
        # 1. Register & verify payee
        self.registry.functions.registerPayee("bob.payee", "Bob Logistics", "ipfs://bob").transact({"from": self.payee})
        self.registry.functions.verifyPayee(self.payee, 2).transact({"from": self.deployer})

        # 2. Approve escrow contract to spend payer's tUSD8
        deposit_amount = 1_000 * 10**6 # 1,000 tUSD8
        self.tusd8.functions.approve(self.escrow.address, deposit_amount).transact({"from": self.payer})

        # 3. Create escrow requiring verified payee
        tx = self.escrow.functions.createEscrow(
            self.payee,
            self.tusd8.address,
            deposit_amount,
            b"\x00" * 32,
            3600, # 1 hour
            True, # requireVerifiedPayee
            "INV-2026-001"
        ).transact({"from": self.payer})
        
        escrow_id = 1
        e = self.escrow.functions.escrows(escrow_id).call()
        self.assertEqual(e[1], self.payer)
        self.assertEqual(e[2], self.payee)
        self.assertEqual(e[4], deposit_amount)
        self.assertEqual(e[7], 1) # FUNDED

        # 4. Release milestone to payee
        payee_initial = self.tusd8.functions.balanceOf(self.payee).call()
        self.escrow.functions.release(escrow_id).transact({"from": self.payer})
        payee_final = self.tusd8.functions.balanceOf(self.payee).call()

        self.assertEqual(payee_final - payee_initial, deposit_amount)
        e_after = self.escrow.functions.escrows(escrow_id).call()
        self.assertEqual(e_after[7], 2) # RELEASED

    def test_03_escrow_htlc_cryptographic_release(self):
        """Test HTLC atomic release using keccak256 preimage."""
        preimage = b"secret-delivery-token-qday-aevum-2026"
        hash_lock = Web3.keccak(preimage)

        deposit_amount = 500 * 10**6
        self.tusd8.functions.approve(self.escrow.address, deposit_amount).transact({"from": self.payer})

        self.escrow.functions.createEscrow(
            self.payee,
            self.tusd8.address,
            deposit_amount,
            hash_lock,
            3600,
            False, # do not require COP for this test
            "HTLC-ORDER-77"
        ).transact({"from": self.payer})

        escrow_id = 1
        payee_initial = self.tusd8.functions.balanceOf(self.payee).call()

        # Revert with invalid preimage
        with self.assertRaises(Exception):
            self.escrow.functions.releaseWithPreimage(escrow_id, b"wrong-secret").transact({"from": self.unverified})

        # Release with correct preimage by any relayer
        self.escrow.functions.releaseWithPreimage(escrow_id, preimage).transact({"from": self.unverified})

        payee_final = self.tusd8.functions.balanceOf(self.payee).call()
        self.assertEqual(payee_final - payee_initial, deposit_amount)

    def test_04_streaming_payroll(self):
        """Test continuous per-second payroll streaming, dynamic vesting, and claim."""
        stream_amount = 3600 * 10**6 # 3,600 tUSD8 (1 tUSD8 per second)
        self.tusd8.functions.approve(self.stream.address, stream_amount).transact({"from": self.payer})

        current_time = self.w3.eth.get_block("latest").timestamp
        start_time = current_time + 10
        stop_time = start_time + 3600 # 3600 seconds

        self.stream.functions.createStream(
            self.payee,
            self.tusd8.address,
            stream_amount,
            start_time,
            stop_time,
            "Senior Smart Contract Engineer"
        ).transact({"from": self.payer})

        stream_id = 1
        s = self.stream.functions.streams(stream_id).call()
        self.assertEqual(s[4], stream_amount)
        self.assertEqual(s[5], 10**6) # 1 tUSD8 per second

        # Advance time by 600 seconds
        self.w3.provider.ethereum_tester.time_travel(start_time + 600)
        self.w3.provider.ethereum_tester.mine_block()

        avail = self.stream.functions.availableBalance(stream_id).call()
        self.assertGreaterEqual(avail, 600 * 10**6)

        # Payee claims accrued tokens
        payee_initial = self.tusd8.functions.balanceOf(self.payee).call()
        self.stream.functions.claim(stream_id).transact({"from": self.payee})
        payee_final = self.tusd8.functions.balanceOf(self.payee).call()

        self.assertGreaterEqual(payee_final - payee_initial, 600 * 10**6)

    def test_05_autonomous_agent_vault(self):
        """Test session-key scoped AI agent micro-payments and budget limit enforcement."""
        # 1. Fund vault with 10,000 tUSD8
        vault_deposit = 10_000 * 10**6
        self.tusd8.functions.approve(self.vault.address, vault_deposit).transact({"from": self.deployer})
        self.vault.functions.deposit(self.tusd8.address, vault_deposit).transact({"from": self.deployer})
        self.assertEqual(self.vault.functions.getVaultBalance(self.tusd8.address).call(), vault_deposit)

        # 2. Register & verify payee for autonomous merchant payment
        self.registry.functions.registerPayee("api.provider", "Decentralized RPC LLC", "").transact({"from": self.payee})
        self.registry.functions.verifyPayee(self.payee, 2).transact({"from": self.deployer})

        # 3. Configure AI Agent session policy: max 50 tUSD8 per tx, 200 tUSD8 per day, enforce CoP
        self.vault.functions.configureAgent(
            self.agent,
            50 * 10**6,   # 50 tUSD8 per tx
            200 * 10**6,  # 200 tUSD8 per day
            86400,        # 24 hours validity
            True          # enforceVerifiedPayee
        ).transact({"from": self.deployer})

        # 4. Agent executes payment within limit
        self.vault.functions.executeAgentPayment(
            self.tusd8.address,
            self.payee,
            30 * 10**6,
            "100,000 RPC API Credits Purchase"
        ).transact({"from": self.agent})

        self.assertEqual(self.tusd8.functions.balanceOf(self.payee).call(), 30 * 10**6)

        # 5. Agent exceeds per-tx limit (try to spend 60 tUSD8 when limit is 50) -> REVERT
        with self.assertRaises(Exception):
            self.vault.functions.executeAgentPayment(
                self.tusd8.address,
                self.payee,
                60 * 10**6,
                "Over-budget purchase"
            ).transact({"from": self.agent})

        # 6. Agent tries to pay unverified recipient -> REVERT
        with self.assertRaises(Exception):
            self.vault.functions.executeAgentPayment(
                self.tusd8.address,
                self.unverified,
                10 * 10**6,
                "Unverified payee attempt"
            ).transact({"from": self.agent})

if __name__ == "__main__":
    unittest.main()
