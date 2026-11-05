#!/usr/bin/env bash
# Installs the pinned Solidity dependencies into contracts/lib (needs git + Foundry).
# In a git clone of the repo you can use `git submodule update --init --recursive` instead.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib
[ -d lib/openzeppelin-contracts/contracts ] || git clone --depth 1 --branch v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts.git lib/openzeppelin-contracts
[ -d lib/forge-std/src ] || git clone --depth 1 --branch v1.9.7 https://github.com/foundry-rs/forge-std.git lib/forge-std
echo "Dependencies ready: OpenZeppelin v5.1.0, forge-std v1.9.7"
