#!/bin/bash

set -e  # Exit on error

current_path=$(pwd)

# Install Go
bash "$current_path/install-go.sh"

# Load Go environment
export PATH="$HOME/.go/bin:$PATH"
source "$HOME/.bashrc"

# Raise file descriptor limit
ulimit -n 16384

# Install cosmovisor
go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.5.0
COSMOVISOR_PATH=$(which cosmovisor)
echo "Cosmovisor is installed at: $COSMOVISOR_PATH"

# OS version check
OS=$(awk -F '=' '/^NAME/{print $2}' /etc/os-release | tr -d '"' | awk '{print $1}')
VERSION=$(awk -F '=' '/^VERSION_ID/{print $2}' /etc/os-release | tr -d '"')

BINARY="qubeticsd"
INSTALL_PATH="/usr/local/bin/"
if [[ "$OS" == "Ubuntu" && ("$VERSION" == "22.04" || "$VERSION" == "24.04") ]]; then
  sudo apt-get update
  sudo apt-get install -y build-essential jq wget unzip

  if [ -d "$INSTALL_PATH" ]; then
    sudo cp "$current_path/ubuntu${VERSION}build/$BINARY" "$INSTALL_PATH"
    sudo chmod +x "${INSTALL_PATH}${BINARY}"
    echo "$BINARY installed successfully!"
  else
    echo "Installation path $INSTALL_PATH does not exist."
    exit 1
  fi
else
  echo "Only Ubuntu 22.04 and 24.04 are supported."
  exit 1
fi

# Node configuration

MONIKER="qubetics-node"  
KEYS="mykey"
CHAINID="qubetics_9029-1"
KEYRING="os"
KEYALGO="eth_secp256k1"
LOGLEVEL="info"
HOMEDIR="/data/.tmp-qubeticsd"

# Stop old service if exists
if systemctl is-active --quiet qubeticschain.service; then
    sudo systemctl stop qubeticschain.service
    sudo rm -rf "$HOMEDIR"
    sudo rm -f /etc/systemd/system/qubeticschain.service
fi

CONFIG=$HOMEDIR/config/config.toml
APP_TOML=$HOMEDIR/config/app.toml
CLIENT=$HOMEDIR/config/client.toml
GENESIS=$HOMEDIR/config/genesis.json
TMP_GENESIS=$HOMEDIR/config/tmp_genesis.json

# Ask to overwrite
if [ -d "$HOMEDIR" ]; then
  read -p "Overwrite the existing configuration and start a new local node? [y/N]: " overwrite
else
  overwrite="y"
fi

if [[ "$overwrite" =~ ^[Yy]$ ]]; then
  sudo rm -rf "$HOMEDIR"
  qubeticsd config keyring-backend $KEYRING --home "$HOMEDIR"
  qubeticsd config chain-id $CHAINID --home "$HOMEDIR"

  echo "====================== Save These Keys & Mnemonic ======================="
  qubeticsd keys add $KEYS --keyring-backend $KEYRING --algo $KEYALGO --home "$HOMEDIR"
  echo "========================================================================="

  qubeticsd init "$MONIKER" -o --chain-id $CHAINID --home "$HOMEDIR"
  qubeticsd add-genesis-account $KEYS 100000000000000000000000000000tics --keyring-backend $KEYRING --home "$HOMEDIR"
  qubeticsd gentx $KEYS 1000000000000000000000000tics --keyring-backend $KEYRING --chain-id $CHAINID --home "$HOMEDIR"
  qubeticsd collect-gentxs --home "$HOMEDIR"

  # Modify genesis denom and config parameters
  declare -a jq_updates=(
    '.app_state["staking"]["params"]["bond_denom"]="tics"'
    '.app_state["crisis"]["constant_fee"]["denom"]="tics"'
    '.app_state["gov"]["deposit_params"]["min_deposit"][0]["denom"]="tics"'
    '.app_state["evm"]["params"]["evm_denom"]="tics"'
    '.app_state["mint"]["params"]["mint_denom"]="tics"'
    '.consensus_params["block"]["max_gas"]="10000000"'
    '.consensus_params["block"]["max_bytes"]="5242880"'
    '.app_state["mint"]["params"]["blocks_per_year"]="5256000"'
    '.app_state["gov"]["deposit_params"]["max_deposit_period"]="1800s"'
    '.app_state["gov"]["voting_params"]["voting_period"]="1800s"'
    '.app_state["staking"]["params"]["unbonding_time"]="1800s"'
    '.app_state["slashing"]["params"]["downtime_jail_duration"]="600s"'
  )

  for jq_cmd in "${jq_updates[@]}"; do
    jq "$jq_cmd" "$GENESIS" > "$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
  done

  # Config updates
  sed -i 's/timeout_commit = "3s"/timeout_commit = "6s"/g' "$CONFIG"
  sed -i 's/prometheus = false/prometheus = true/' "$CONFIG"
  sed -i 's/localhost/0.0.0.0/g' "$CONFIG" "$CLIENT" "$APP_TOML"
  sed -i 's/127.0.0.1/0.0.0.0/g' "$CONFIG" "$CLIENT" "$APP_TOML"
  sed -i 's/seeds = ""/seeds = ""/g' "$CONFIG"
  sed -i 's/enable = false/enable = true/g' "$APP_TOML"
  sed -i 's/swagger = false/swagger = true/g' "$APP_TOML"
  sed -i 's/enabled-unsafe-cors = false/enabled-unsafe-cors = true/g' "$APP_TOML"
  sed -i 's/minimum-gas-prices = "0tics"/minimum-gas-prices = "0.25tics"/g' "$APP_TOML"

  sed -i 's/persistent_peers = ""/persistent_peers = "b3262f53ab7bb3341807b853566a88415363bc42@114.119.184.52:26656,c4bd2d6b9b05cd2dc7e582d051168ffbdbcd4483@124.243.136.185:26656"/g' "$CONFIG"

  cp "$current_path/genesis.json" "$GENESIS"
  qubeticsd validate-genesis --home "$HOMEDIR"

  echo "export DAEMON_NAME=qubeticsd" >> ~/.profile
  echo "export DAEMON_HOME=$HOMEDIR" >> ~/.profile
  source ~/.profile

  cosmovisor init "${INSTALL_PATH}${BINARY}"

  TENDERMINTPUBKEY=$(qubeticsd tendermint show-validator --home $HOMEDIR | grep "key" | cut -c12-)
  NodeId=$(qubeticsd tendermint show-node-id --home $HOMEDIR)
  BECH32ADDRESS=$(qubeticsd keys show ${KEYS} --home $HOMEDIR --keyring-backend $KEYRING | grep "address" | cut -c12-)

  echo "===================================================================="
  echo "Tendermint PubKey: $TENDERMINTPUBKEY"
  echo "BECH32 Address   : $BECH32ADDRESS"
  echo "Node ID          : $NodeId"
  echo "===================================================================="
fi

# Create systemd service with fixed ExecStart and Environment using $HOMEDIR and $COSMOVISOR_PATH directly
sudo tee /etc/systemd/system/qubeticschain.service > /dev/null <<EOF
[Unit]
Description=qubetics Node
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/root/go/bin/cosmovisor run start --home /data/.tmp-qubeticsd
Restart=always
RestartSec=3
LimitNOFILE=16384
Environment=DAEMON_NAME=qubeticsd
Environment=DAEMON_HOME=/data/.tmp-qubeticsd
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=false
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
Environment=DAEMON_LOG_BUFFER_SIZE=512
Environment=UNSAFE_SKIP_BACKUP=false


[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable qubeticschain.service
sudo systemctl start qubeticschain.service

