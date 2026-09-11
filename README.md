# Vesu V2 Contracts

This repository contains the Cairo contracts for the Vesu V2 lending protocol.

## Overview

<p align="center">
  <img width="4352" height="2049" alt="vesu-v2-architecture" src="https://github.com/user-attachments/assets/9ad25c05-cb6e-4f0d-b8d7-3c9b6784bec0" />
</p>

## Setup

### Requirements

This project uses Starknet Foundry for testing. To install Starknet Foundry follow [these instructions](https://foundry-rs.github.io/starknet-foundry/getting-started/installation.html).

### Install

We advise that you use [nvm](https://github.com/nvm-sh/nvm) to manage your Node versions.

node v19.7.0

```sh
yarn
```

### Test

`Scarb.toml` is generated from `Scarb.toml.template`, which carries a `MAINNET_RPC_URL` placeholder
rather than a real endpoint. Set `MAINNET_RPC_URL` in `.env` (see `.env.example`) and substitute it in
before running the tests:

```sh
./scripts/patchScarbToml.sh
scarb run test
```

The fork tests need an **archive** node: they read state at mainnet block 14,500,000. Without the patch
step `snforge` refuses to start with `relative URL without a base: "MAINNET_RPC_URL"`. Note that the
patched `Scarb.toml` will then show as modified — take care not to commit it with the endpoint in it.

## Scripts

### Prerequisite

Copy and update the contents of `.env.example` to `.env`.

### Declare and deploy contracts

Declare and deploy all contracts under `src` using the account with `PRIVATE_KEY` and `ADDRESS` specified in `.env`

```sh
scarb run deployMainnet
POOL=<POOL_ADDRESS> scarb run verifyPool
```

### Check the pool state

```sh
scarb run printPoolParams
scarb run checkSecurityInvariants
```
