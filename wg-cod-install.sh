#!/bin/bash
# =============================================================================
# WireGuard + pivpn Open NAT Installer for Call of Duty (Single User)
# Ubuntu 22.04 VPS
# =============================================================================
# This script:
#   1. Installs pivpn with WireGuard
#   2. Creates a player1 client (IP: 10.221.144.2)
#   3. Configures full Open NAT with all CoD PC ports
#   4. Persists all rules across reboots
#
# USAGE:
#   chmod +x wg-cod-install.sh
#   sudo ./wg-cod-install.sh
# =============================================================================

set -e

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo ./wg-cod-install.sh"

# ── Detect network interface and public IP ────────────────────────────────────
PUB_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[[ -z "$PUB_IFACE" ]] && error "Could not detect public network interface."
PUB_IP=$(ip -4 addr show "$PUB_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
[[ -z "$PUB_IP" ]] && error "Could not detect public IP on ${PUB_IFACE}."

# ── Fixed config values (matching your working setup) ────────────────────────
WG_CONF="/etc/wireguard/wg0.conf"
WG_NET="10.221.144.0/24"
WG_SERVER_IP="10.221.144.1"
PLAYER1_IP="10.221.144.2"
WG_PORT="51820"
CLIENT_NAME="player1"

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  WireGuard CoD Open NAT Installer"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Public interface : ${GREEN}${PUB_IFACE}${NC}"
echo -e "  Public IP        : ${GREEN}${PUB_IP}${NC}"
echo -e "  WireGuard subnet : ${GREEN}${WG_NET}${NC}"
echo -e "  Server WG IP     : ${GREEN}${WG_SERVER_IP}${NC}"
echo -e "  Player1 WG IP    : ${GREEN}${PLAYER1_IP}${NC}"
echo -e "  WireGuard port   : ${GREEN}${WG_PORT}${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { info "Aborted."; exit 0; }

# ── Step 1: System update ─────────────────────────────────────────────────────
info "Updating package lists..."
apt-get update -qq
success "Package lists updated."

# ── Step 2: Install dependencies ──────────────────────────────────────────────
info "Installing WireGuard and iptables-persistent..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard wireguard-tools iptables-persistent > /dev/null 2>&1
success "Dependencies installed."

# ── Step 3: Enable IP forwarding ─────────────────────────────────────────────
info "Enabling IP forwarding..."
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || \
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p > /dev/null
success "IP forwarding enabled."

# ── Step 4: Install pivpn non-interactively ───────────────────────────────────
info "Installing pivpn (this may take a minute)..."

# pivpn uses debconf/unattended mode when these are set
export PIVPN_UNATTENDED=1

# Write pivpn answer file
PIVPN_ANSWERS=$(mktemp)
cat > "$PIVPN_ANSWERS" <<EOF
IPv4dev=${PUB_IFACE}
IPv4addr=${PUB_IP}
IPv4gw=$(ip route | grep default | awk '{print $3}' | head -1)
pivpnProto=wireguard
pivpnPORT=${WG_PORT}
pivpnDNS1=1.1.1.1
pivpnDNS2=8.8.8.8
pivpnSEARCHDOMAIN=
pivpnHOST=${PUB_IP}
pivpnPERSISTENTKEEPALIVE=25
UNATTUPG=1
EOF

curl -fsSL https://install.pivpn.io -o /tmp/pivpn-install.sh
bash /tmp/pivpn-install.sh --unattended "$PIVPN_ANSWERS" > /tmp/pivpn-install.log 2>&1 || {
    warn "pivpn unattended install may have had issues — checking if WireGuard config exists..."
}

# Give it a moment to settle
sleep 3

# ── Step 5: Verify WireGuard was set up ───────────────────────────────────────
if [[ ! -f "$WG_CONF" ]]; then
    warn "pivpn unattended install did not create wg0.conf."
    warn "Falling back to manual WireGuard setup..."

    # Generate server keys
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard
    cd /etc/wireguard
    umask 077
    wg genkey | tee server_private.key | wg pubkey > server_public.key
    SERVER_PRIVKEY=$(cat server_private.key)

    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}/24
MTU = 1420
ListenPort = ${WG_PORT}
EOF
    success "Manual WireGuard config created."
fi

# ── Step 6: Add player1 peer ──────────────────────────────────────────────────
info "Generating player1 keys..."
cd /etc/wireguard
umask 077
wg genkey | tee player1_private.key | wg pubkey > player1_public.key
wg genpsk > player1_psk.key

PLAYER1_PRIVKEY=$(cat player1_private.key)
PLAYER1_PUBKEY=$(cat player1_public.key)
PLAYER1_PSK=$(cat player1_psk.key)
SERVER_PUBKEY=$(wg pubkey < <(grep PrivateKey "$WG_CONF" | awk '{print $3}'))

# Add peer to server config if not already present
if ! grep -q "$PLAYER1_PUBKEY" "$WG_CONF" 2>/dev/null; then
    cat >> "$WG_CONF" <<EOF

### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = ${PLAYER1_PUBKEY}
PresharedKey = ${PLAYER1_PSK}
AllowedIPs = ${PLAYER1_IP}/32
### end ${CLIENT_NAME} ###
EOF
    success "player1 peer added to server config."
else
    success "player1 peer already exists in server config."
fi

# Create client config directory
mkdir -p /etc/wireguard/configs

cat > "/etc/wireguard/configs/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${PLAYER1_PRIVKEY}
Address = ${PLAYER1_IP}/24
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${PLAYER1_PSK}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
success "player1 client config saved to /etc/wireguard/configs/${CLIENT_NAME}.conf"

# ── Step 7: Write complete wg0.conf with all NAT + port forward rules ─────────
info "Writing NAT and port forwarding rules to wg0.conf..."

# Extract existing peer blocks to preserve them
PEERS=$(awk '/^\[Peer\]/{found=1} found{print}' "$WG_CONF")
SERVER_PRIVKEY=$(grep PrivateKey "$WG_CONF" | awk '{print $3}')

cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${WG_SERVER_IP}/24
MTU = 1420
ListenPort = ${WG_PORT}

# ── NAT ───────────────────────────────────────────────────────────────────────
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${PUB_IFACE} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

# ── TCP port forwards ─────────────────────────────────────────────────────────
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 3074 -j DNAT --to-dest ${PLAYER1_IP}:3074
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 27015 -j DNAT --to-dest ${PLAYER1_IP}:27015
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 27036 -j DNAT --to-dest ${PLAYER1_IP}:27036
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 4000 -j DNAT --to-dest ${PLAYER1_IP}:4000
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 6112:6119 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 20500 -j DNAT --to-dest ${PLAYER1_IP}:20500
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 20510 -j DNAT --to-dest ${PLAYER1_IP}:20510
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 27014:27050 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p tcp --dport 28960 -j DNAT --to-dest ${PLAYER1_IP}:28960

# ── UDP port forwards ─────────────────────────────────────────────────────────
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 3074 -j DNAT --to-dest ${PLAYER1_IP}:3074
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 27015 -j DNAT --to-dest ${PLAYER1_IP}:27015
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 27031:27036 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 3478 -j DNAT --to-dest ${PLAYER1_IP}:3478
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 4379:4380 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 6112:6119 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 20500 -j DNAT --to-dest ${PLAYER1_IP}:20500
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 20510 -j DNAT --to-dest ${PLAYER1_IP}:20510
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 27000:27031 -j DNAT --to-dest ${PLAYER1_IP}
PostUp = iptables -t nat -A PREROUTING -i ${PUB_IFACE} -p udp --dport 28960 -j DNAT --to-dest ${PLAYER1_IP}:28960

# ── NAT teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${PUB_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

# ── TCP teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 3074 -j DNAT --to-dest ${PLAYER1_IP}:3074
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 27015 -j DNAT --to-dest ${PLAYER1_IP}:27015
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 27036 -j DNAT --to-dest ${PLAYER1_IP}:27036
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 4000 -j DNAT --to-dest ${PLAYER1_IP}:4000
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 6112:6119 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 20500 -j DNAT --to-dest ${PLAYER1_IP}:20500
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 20510 -j DNAT --to-dest ${PLAYER1_IP}:20510
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 27014:27050 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p tcp --dport 28960 -j DNAT --to-dest ${PLAYER1_IP}:28960

# ── UDP teardown ──────────────────────────────────────────────────────────────
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 3074 -j DNAT --to-dest ${PLAYER1_IP}:3074
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 27015 -j DNAT --to-dest ${PLAYER1_IP}:27015
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 27031:27036 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 3478 -j DNAT --to-dest ${PLAYER1_IP}:3478
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 4379:4380 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 6112:6119 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 20500 -j DNAT --to-dest ${PLAYER1_IP}:20500
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 20510 -j DNAT --to-dest ${PLAYER1_IP}:20510
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 27000:27031 -j DNAT --to-dest ${PLAYER1_IP}
PostDown = iptables -t nat -D PREROUTING -i ${PUB_IFACE} -p udp --dport 28960 -j DNAT --to-dest ${PLAYER1_IP}:28960

### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = ${PLAYER1_PUBKEY}
PresharedKey = ${PLAYER1_PSK}
AllowedIPs = ${PLAYER1_IP}/32
### end ${CLIENT_NAME} ###
EOF
success "wg0.conf written."

# ── Step 8: Configure UFW ─────────────────────────────────────────────────────
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    info "Configuring UFW rules..."
    ufw allow ${WG_PORT}/udp       comment 'WireGuard'        > /dev/null
    ufw allow 3074/tcp             comment 'CoD TCP'          > /dev/null
    ufw allow 3074/udp             comment 'CoD UDP'          > /dev/null
    ufw allow 27015/tcp            comment 'Steam TCP'        > /dev/null
    ufw allow 27015/udp            comment 'Steam UDP'        > /dev/null
    ufw allow 27036/tcp            comment 'Steam TCP'        > /dev/null
    ufw allow 27031:27036/udp      comment 'Steam UDP'        > /dev/null
    ufw allow 4000/tcp             comment 'CoD TCP'          > /dev/null
    ufw allow 6112:6119/tcp        comment 'CoD TCP'          > /dev/null
    ufw allow 6112:6119/udp        comment 'CoD UDP'          > /dev/null
    ufw allow 20500/tcp            comment 'CoD TCP'          > /dev/null
    ufw allow 20500/udp            comment 'CoD UDP'          > /dev/null
    ufw allow 20510/tcp            comment 'CoD TCP'          > /dev/null
    ufw allow 20510/udp            comment 'CoD UDP'          > /dev/null
    ufw allow 27014:27050/tcp      comment 'CoD/Steam TCP'    > /dev/null
    ufw allow 27000:27031/udp      comment 'CoD/Steam UDP'    > /dev/null
    ufw allow 28960/tcp            comment 'CoD TCP'          > /dev/null
    ufw allow 28960/udp            comment 'CoD UDP'          > /dev/null
    ufw allow 3478/udp             comment 'CoD UDP'          > /dev/null
    ufw allow 4379:4380/udp        comment 'CoD UDP'          > /dev/null
    ufw reload > /dev/null
    success "UFW rules configured."
else
    warn "UFW not active — skipping firewall rules."
fi

# ── Step 9: Enable and start WireGuard ───────────────────────────────────────
info "Enabling and starting WireGuard..."
systemctl enable wg-quick@wg0 > /dev/null 2>&1
systemctl restart wg-quick@wg0
sleep 2
if systemctl is-active --quiet wg-quick@wg0; then
    success "WireGuard is running."
else
    error "WireGuard failed to start. Check: journalctl -u wg-quick@wg0"
fi

# ── Step 10: Save iptables rules ──────────────────────────────────────────────
info "Saving iptables rules for persistence..."
netfilter-persistent save > /dev/null 2>&1
success "iptables rules saved."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "WireGuard status:"
wg show
echo ""
echo -e "${YELLOW}Player1 client config:${NC}"
echo -e "  File : ${CYAN}/etc/wireguard/configs/player1.conf${NC}"
echo -e "  View : ${CYAN}cat /etc/wireguard/configs/player1.conf${NC}"
echo -e "  QR   : ${CYAN}qrencode -t ansiutf8 < /etc/wireguard/configs/player1.conf${NC}"
echo ""
echo -e "${YELLOW}Useful commands:${NC}"
echo -e "  Monitor tunnel  : ${CYAN}watch -n2 sudo wg show${NC}"
echo -e "  Watch CoD ports : ${CYAN}sudo tcpdump -i wg0 -n udp port 3074${NC}"
echo -e "  View NAT rules  : ${CYAN}sudo iptables -t nat -L PREROUTING -n --line-numbers${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy /etc/wireguard/configs/player1.conf to the client PC"
echo "  2. Import into WireGuard app and connect"
echo "  3. Launch CoD → Settings → Network → confirm NAT Type = Open"
echo ""
