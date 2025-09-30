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

```sh
scarb run test
```

## Deployment

### Prerequisite

Copy and update the contents of `.env.example` to `.env`.

### Declare and deploy contracts

Declare and deploy all contracts under `src` using the account with `PRIVATE_KEY` and `ADDRESS` specified in `.env`

```sh
scarb run deployProtocol
scarb run deploySepolia
scarb run deployMainnet
```
