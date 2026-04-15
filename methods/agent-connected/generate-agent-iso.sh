#!/bin/bash

# =============================================================
# OpenShift Agent-Based Installation — ISO Generator
# =============================================================
# Run this on the bastion AFTER setup-bastion.sh has completed
# (DNS + HAProxy must already be up).
#
# What this script does:
#   1. Creates the install directory
#   2. Writes agent-config.yaml   (static IPs, MACs, roles)
#   3. Writes install-config.yaml (cluster topology, networking)
#   4. Backs up both config files
#   5. Installs nmstate (required by openshift-install)
#   6. Generates agent.x86_64.iso
#   7. Prints monitoring commands
#
# Masters are always 3.
# Workers: add as many as you need in the WORKERS array below.
#
# WORKER FORMAT: "hostname:ip:mac"
# =============================================================

set -euo pipefail

# ----------------------------
# ENV VARIABLES — edit these
# ----------------------------
export DOMAIN="anishs.xyz"
export CLUSTER_NAME="ocp"
export OCP_VERSION="4.20.13"         # must match your RHCOS ISO version

# Network
export NETWORK_INTERFACE="ens3"
export PREFIX_LENGTH="23"
export GATEWAY="190.170.30.1"
export DNS_SERVER="190.170.31.35"

# Masters — rendezvousIP must be master1
export MASTER1_HOSTNAME="master-1.${CLUSTER_NAME}.${DOMAIN}"
export MASTER1_IP="190.170.31.24"

export MASTER1_MAC="50:6b:8d:97:3b:22"

export MASTER2_HOSTNAME="master-2.${CLUSTER_NAME}.${DOMAIN}"
export MASTER2_IP="190.170.31.56"
export MASTER2_MAC="50:6b:8d:fc:4f:e4"

export MASTER3_HOSTNAME="master-3.${CLUSTER_NAME}.${DOMAIN}"
export MASTER3_IP="190.170.31.25"
export MASTER3_MAC="50:6b:8d:e5:0c:9c"

# rendezvousIP = the node that runs Assisted Service first (bootstrap leader)
# Must match one of the master IPs above
export RENDEZVOUS_IP="$MASTER1_IP"

# ----------------------------
# WORKERS — add as many as needed
# FORMAT: "hostname:ip:mac"
# ----------------------------
WORKERS=(
    "worker.${CLUSTER_NAME}.${DOMAIN}:190.170.31.18:50:6b:8d:cf:a0:04"
    # "worker-2.${CLUSTER_NAME}.${DOMAIN}:190.170.31.19:00:50:56:85:55:55"
)

# ----------------------------
# Cluster topology
# (worker replica count = number of entries in WORKERS array)
# ----------------------------
export MASTER_REPLICAS=3
export MACHINE_NETWORK_CIDR="190.170.30.0/23"
export CLUSTER_NETWORK_CIDR="10.128.0.0/14"
export CLUSTER_HOST_PREFIX="23"
export SERVICE_NETWORK_CIDR="172.30.0.0/16"
export NETWORK_TYPE="OVNKubernetes"

# ----------------------------
# Credentials
# Pull secret from: https://console.redhat.com/openshift/downloads
# SSH_KEY: public key from your bastion (~/.ssh/id_rsa.pub)
# ----------------------------
export PULL_SECRET=''

export SSH_KEY=''

# ----------------------------
# Install directory
# ----------------------------
export INSTALL_DIR="/root/agent"

# =============================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================

# ----------------------------
# Pre-flight checks
# ----------------------------
preflight_fail=0

# ----------------------------
# GLIBC version check
# OCP 4.14+ clients require GLIBC >= 2.32 (RHEL 9 / CentOS Stream 9).
# RHEL 8 ships GLIBC 2.28 and will not run these binaries.
# ----------------------------
GLIBC_MIN_MAJOR=2
GLIBC_MIN_MINOR=32
GLIBC_VERSION=$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')
GLIBC_MAJOR=$(echo "$GLIBC_VERSION" | cut -d. -f1)
GLIBC_MINOR=$(echo "$GLIBC_VERSION" | cut -d. -f2)

if [[ "$GLIBC_MAJOR" -lt "$GLIBC_MIN_MAJOR" ]] || \
   { [[ "$GLIBC_MAJOR" -eq "$GLIBC_MIN_MAJOR" ]] && [[ "$GLIBC_MINOR" -lt "$GLIBC_MIN_MINOR" ]]; }; then
    echo "[ERROR] GLIBC ${GLIBC_VERSION} detected — OCP ${OCP_VERSION} requires GLIBC >= ${GLIBC_MIN_MAJOR}.${GLIBC_MIN_MINOR}."
    echo "  This script must run on RHEL 9 / CentOS Stream 9 or newer."
    preflight_fail=1
fi

if [[ -z "$PULL_SECRET" ]]; then
    echo "[ERROR] PULL_SECRET is empty. Paste your pull secret from console.redhat.com."
    preflight_fail=1
fi

if [[ -z "$SSH_KEY" ]]; then
    echo "[ERROR] SSH_KEY is empty. Run: cat ~/.ssh/id_rsa.pub  (generate with ssh-keygen if needed)"
    preflight_fail=1
fi

if ! command -v openshift-install &>/dev/null; then
    echo "[INFO] openshift-install not found. Downloading version ${OCP_VERSION}..."
    OCP_TARBALL="openshift-install-linux-${OCP_VERSION}.tar.gz"
    OCP_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/${OCP_TARBALL}"
    TMP_DIR=$(mktemp -d)
    if curl -fL --retry 3 --progress-bar "$OCP_URL" -o "${TMP_DIR}/${OCP_TARBALL}"; then
        tar -xzf "${TMP_DIR}/${OCP_TARBALL}" -C "$TMP_DIR" openshift-install
        mv "${TMP_DIR}/openshift-install" /usr/local/bin/openshift-install
        chmod +x /usr/local/bin/openshift-install
        rm -rf "$TMP_DIR"
        echo "  [OK] openshift-install ${OCP_VERSION} installed"
    else
        echo "[ERROR] Failed to download openshift-install from:"
        echo "        $OCP_URL"
        echo "        Check the version at: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        rm -rf "$TMP_DIR"
        preflight_fail=1
    fi
fi

if ! command -v oc &>/dev/null; then
    echo "[INFO] oc not found. Downloading version ${OCP_VERSION}..."
    OC_TARBALL="openshift-client-linux-${OCP_VERSION}.tar.gz"
    OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/${OC_TARBALL}"
    TMP_DIR=$(mktemp -d)
    if curl -fL --retry 3 --progress-bar "$OC_URL" -o "${TMP_DIR}/${OC_TARBALL}"; then
        tar -xzf "${TMP_DIR}/${OC_TARBALL}" -C "$TMP_DIR" oc
        mv "${TMP_DIR}/oc" /usr/local/bin/oc
        chmod +x /usr/local/bin/oc
        rm -rf "$TMP_DIR"
        echo "  [OK] oc ${OCP_VERSION} installed"
    else
        echo "[ERROR] Failed to download oc from:"
        echo "        $OC_URL"
        echo "        Check the version at: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        rm -rf "$TMP_DIR"
        preflight_fail=1
    fi
fi

if [[ "$preflight_fail" -eq 1 ]]; then
    echo ""
    echo "Fix the errors above, then re-run."
    exit 1
fi

WORKER_REPLICAS=${#WORKERS[@]}

echo "============================================="
echo " OpenShift Agent ISO Generator"
echo "============================================="
echo " Domain          : $DOMAIN"
echo " Cluster         : $CLUSTER_NAME"
echo " Rendezvous IP   : $RENDEZVOUS_IP"
echo " Master-1        : $MASTER1_HOSTNAME ($MASTER1_IP) MAC=$MASTER1_MAC"
echo " Master-2        : $MASTER2_HOSTNAME ($MASTER2_IP) MAC=$MASTER2_MAC"
echo " Master-3        : $MASTER3_HOSTNAME ($MASTER3_IP) MAC=$MASTER3_MAC"
echo " Workers         : $WORKER_REPLICAS"
for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(  echo "$W" | cut -d: -f2)
    WMAC=$( echo "$W" | cut -d: -f3-) # handles MACs with colons
    echo "   $WNAME ($WIP) MAC=$WMAC"
done
echo " Interface       : $NETWORK_INTERFACE  prefix=/$PREFIX_LENGTH"
echo " Gateway         : $GATEWAY"
echo " DNS             : $DNS_SERVER"
echo " Machine CIDR    : $MACHINE_NETWORK_CIDR"
echo " Cluster CIDR    : $CLUSTER_NETWORK_CIDR/$CLUSTER_HOST_PREFIX"
echo " Service CIDR    : $SERVICE_NETWORK_CIDR"
echo " Install dir     : $INSTALL_DIR"
echo " openshift-install: $(openshift-install version | head -1)"
echo "============================================="
read -rp "Proceed? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

# =============================================================
# PART 1 — Install nmstate
# =============================================================

echo ""
echo "============================================="
echo " PART 1 — nmstate"
echo "============================================="
echo "[1/1] Installing nmstate..."

if command -v nmstatectl &>/dev/null; then
    echo "  nmstate already installed: $(nmstatectl version 2>/dev/null || echo 'ok')"
else
    if ! dnf repolist enabled 2>/dev/null | grep -q "^[a-zA-Z]"; then
        echo "  No repos found. Adding CentOS Stream 8 vault repos..."
        cat > /etc/yum.repos.d/centos.repo <<'REPO'
[baseos]
name=CentOS Stream 8 - BaseOS
baseurl=http://vault.centos.org/8-stream/BaseOS/x86_64/os/
enabled=1
gpgcheck=0

[appstream]
name=CentOS Stream 8 - AppStream
baseurl=http://vault.centos.org/8-stream/AppStream/x86_64/os/
enabled=1
gpgcheck=0
REPO
    fi
    dnf install -y /usr/bin/nmstatectl
    echo "  nmstate installed."
fi

# =============================================================
# PART 2 — Install directory
# =============================================================

echo ""
echo "============================================="
echo " PART 2 — Install directory"
echo "============================================="
echo "[1/1] Creating $INSTALL_DIR ..."

if [[ -d "$INSTALL_DIR" ]]; then
    echo "  Directory already exists. Checking for stale ISO..."
    if [[ -f "$INSTALL_DIR/agent.x86_64.iso" ]]; then
        read -rp "  agent.x86_64.iso already present. Overwrite? (yes/no): " OW
        [[ "$OW" != "yes" ]] && echo "Aborted." && exit 0
        rm -f "$INSTALL_DIR/agent.x86_64.iso"
        echo "  Removed stale ISO."
    fi
else
    mkdir -p "$INSTALL_DIR"
    echo "  Created $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# =============================================================
# PART 3 — agent-config.yaml
# =============================================================

echo ""
echo "============================================="
echo " PART 3 — agent-config.yaml"
echo "============================================="
echo "[1/1] Writing agent-config.yaml..."

cat > agent-config.yaml <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${RENDEZVOUS_IP}
hosts:
  - hostname: ${MASTER1_HOSTNAME}
    role: master
    interfaces:
      - name: ${NETWORK_INTERFACE}
        macAddress: ${MASTER1_MAC}
    networkConfig:
      interfaces:
        - name: ${NETWORK_INTERFACE}
          type: ethernet
          state: up
          mac-address: ${MASTER1_MAC}
          ipv4:
            enabled: true
            address:
              - ip: ${MASTER1_IP}
                prefix-length: ${PREFIX_LENGTH}
            dhcp: false
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${NETWORK_INTERFACE}
            table-id: 254

  - hostname: ${MASTER2_HOSTNAME}
    role: master
    interfaces:
      - name: ${NETWORK_INTERFACE}
        macAddress: ${MASTER2_MAC}
    networkConfig:
      interfaces:
        - name: ${NETWORK_INTERFACE}
          type: ethernet
          state: up
          mac-address: ${MASTER2_MAC}
          ipv4:
            enabled: true
            address:
              - ip: ${MASTER2_IP}
                prefix-length: ${PREFIX_LENGTH}
            dhcp: false
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${NETWORK_INTERFACE}
            table-id: 254

  - hostname: ${MASTER3_HOSTNAME}
    role: master
    interfaces:
      - name: ${NETWORK_INTERFACE}
        macAddress: ${MASTER3_MAC}
    networkConfig:
      interfaces:
        - name: ${NETWORK_INTERFACE}
          type: ethernet
          state: up
          mac-address: ${MASTER3_MAC}
          ipv4:
            enabled: true
            address:
              - ip: ${MASTER3_IP}
                prefix-length: ${PREFIX_LENGTH}
            dhcp: false
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${NETWORK_INTERFACE}
            table-id: 254
EOF

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(  echo "$W" | cut -d: -f2)
    WMAC=$( echo "$W" | cut -d: -f3-)
    cat >> agent-config.yaml <<EOF

  - hostname: ${WNAME}
    role: worker
    interfaces:
      - name: ${NETWORK_INTERFACE}
        macAddress: ${WMAC}
    networkConfig:
      interfaces:
        - name: ${NETWORK_INTERFACE}
          type: ethernet
          state: up
          mac-address: ${WMAC}
          ipv4:
            enabled: true
            address:
              - ip: ${WIP}
                prefix-length: ${PREFIX_LENGTH}
            dhcp: false
      dns-resolver:
        config:
          server:
            - ${DNS_SERVER}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${NETWORK_INTERFACE}
            table-id: 254
EOF
done

cp agent-config.yaml agent-config.yaml.bkp
echo "  agent-config.yaml written and backed up."

# =============================================================
# PART 4 — install-config.yaml
# =============================================================

echo ""
echo "============================================="
echo " PART 4 — install-config.yaml"
echo "============================================="
echo "[1/1] Writing install-config.yaml..."

cat > install-config.yaml <<EOF
apiVersion: v1
baseDomain: ${DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: ${WORKER_REPLICAS}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: ${MASTER_REPLICAS}
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_HOST_PREFIX}
  machineNetwork:
  - cidr: ${MACHINE_NETWORK_CIDR}
  networkType: ${NETWORK_TYPE}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
platform:
  none: {}
publish: External
EOF

# Write credentials separately — avoids heredoc expansion issues with JSON
printf "pullSecret: '%s'\n" "${PULL_SECRET}" >> install-config.yaml
printf "sshKey: '%s'\n"     "${SSH_KEY}"     >> install-config.yaml

cp install-config.yaml install-config.yaml.bkp
echo "  install-config.yaml written and backed up."

# ----------------------------
# Show install dir contents
# ----------------------------
echo ""
echo "Install directory contents:"
ls -lh "$INSTALL_DIR"

# =============================================================
# PART 5 — Generate Agent ISO
# =============================================================

echo ""
echo "============================================="
echo " PART 5 — Generating Agent ISO"
echo "============================================="
echo "[1/1] Running: openshift-install agent create image"
echo "  (this consumes agent-config.yaml and install-config.yaml)"
echo ""

openshift-install agent create image --dir "$INSTALL_DIR" --log-level info

echo ""
if [[ -f "$INSTALL_DIR/agent.x86_64.iso" ]]; then
    ISO_SIZE=$(du -sh "$INSTALL_DIR/agent.x86_64.iso" | cut -f1)
    echo "  [OK] agent.x86_64.iso generated  ($ISO_SIZE)"
else
    echo "  [ERROR] ISO not found after generation. Check logs above."
    exit 1
fi

# =============================================================
# Summary & Next Steps
# =============================================================

echo ""
echo "============================================="
echo " ISO Generation Complete!"
echo "============================================="
echo " ISO location: $INSTALL_DIR/agent.x86_64.iso"
echo ""
echo "------- NEXT STEPS --------------------------"
echo ""
echo " 1. Mount agent.x86_64.iso on ALL master and worker VMs."
echo "    (Edit VM Settings → CD/DVD → select the ISO → connect at power on)"
echo ""
echo " 2. Power on all VMs at the same time."
echo "    rendezvous host (bootstrap leader): $RENDEZVOUS_IP"
echo "    All nodes must be reachable to each other on the same network."
echo ""
echo " 3. On this bastion, watch the install:"
echo ""
echo "    # Wait for bootstrap to complete:"
echo "    openshift-install agent wait-for bootstrap-complete \\"
echo "        --dir $INSTALL_DIR --log-level debug"
echo ""
echo "    # Wait for full install to complete:"
echo "    openshift-install agent wait-for install-complete \\"
echo "        --dir $INSTALL_DIR --log-level debug"
echo ""
echo " 4. After install completes, export kubeconfig and verify:"
echo ""
echo "    export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig"
echo "    oc get nodes"
echo "    oc get co"
echo "    oc get mcp"
echo "    oc get clusterversion"
echo ""
echo " 5. Approve any pending CSRs (if workers are stuck NotReady):"
echo "    oc get csr | grep Pending"
echo "    oc adm certificate approve <csr_name>"
echo ""
echo " 6. Get kubeadmin password:"
echo "    cat $INSTALL_DIR/auth/kubeadmin-password"
echo ""
echo " 7. Get console URL:"
echo "    oc whoami --show-console"
echo "============================================="
