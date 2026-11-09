import os
import json
import solcx

def compile_contracts():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    contracts_dir = os.path.join(base_dir, "contracts")
    artifacts_dir = os.path.join(base_dir, "artifacts")
    os.makedirs(artifacts_dir, exist_ok=True)

    print(f"[*] Scanning contracts in {contracts_dir}...")
    sol_files = []
    for root, _, files in os.walk(contracts_dir):
        for f in files:
            if f.endswith(".sol"):
                sol_files.append(os.path.join(root, f))

    print(f"[*] Found {len(sol_files)} Solidity files.")

    # Configure solcx
    solcx.install_solc("0.8.24")
    solcx.set_solc_version("0.8.24")

    print("[*] Compiling with solc 0.8.24...")
    compiled = solcx.compile_files(
        sol_files,
        output_values=["abi", "bin", "bin-runtime"],
        optimize=True,
        optimize_runs=200,
        solc_version="0.8.24"
    )

    print(f"[+] Compiled {len(compiled)} contract artifacts:")
    for contract_id, data in compiled.items():
        contract_name = contract_id.split(":")[-1]
        out_path = os.path.join(artifacts_dir, f"{contract_name}.json")
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump({
                "contractName": contract_name,
                "abi": data["abi"],
                "bytecode": data["bin"],
                "deployedBytecode": data["bin-runtime"]
            }, f, indent=2)
        print(f"    - {contract_name} -> artifacts/{contract_name}.json")

    print("[+] All contracts compiled successfully!")

if __name__ == "__main__":
    compile_contracts()
