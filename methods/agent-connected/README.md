# OpenShift Agent-Based Connected Install

Tested on **RHEL 9**.

---

## Prerequisites

- RHEL 9 bastion with root access
- All VMs (masters + workers) provisioned and powered off
- Pull secret from [console.redhat.com](https://console.redhat.com/openshift/downloads)
- SSH key generated on the bastion (see below)

---

## Generate SSH Key on Bastion

Run this **once** on the bastion before filling in `generate-agent-iso.sh`:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
# Press Enter twice for no passphrase

cat ~/.ssh/id_rsa.pub
# Copy the full output and paste it into SSH_KEY in generate-agent-iso.sh
```

---

## Step 1 — Gather node details

Run these commands on **each node** before editing the scripts:

```bash
# Get IP address
ip a

# Get MAC address
ip link show <interface>   # e.g. ip link show ens3

# Get hostname
hostname
```

---

## Step 2 — Setup Bastion (DNS + HAProxy)

Edit the variables at the top of `setup-bastion.sh`:

```bash
# Example values — replace with your own
export BASTION_IP="192.168.1.10"
export BASTION_HOSTNAME="bastion"
export DOMAIN="example.com"
export CLUSTER_NAME="ocp"

export MASTER1_IP="192.168.1.21"
export MASTER2_IP="192.168.1.22"
export MASTER3_IP="192.168.1.23"

export API_IP="192.168.1.10"      # usually the bastion IP
export INGRESS_IP="192.168.1.10"  # usually the bastion IP

WORKERS=(
    "worker:192.168.1.31"
)
```

Run the script:

```bash
sudo bash setup-bastion.sh
```

The script installs BIND + HAProxy, writes zone files, and verifies all DNS/port checks pass.

---

## Step 3 — Generate Agent ISO

Edit the variables at the top of `generate-agent-iso.sh`:

```bash
export DOMAIN="example.com"
export CLUSTER_NAME="ocp"
export OCP_VERSION="4.20.13"

export NETWORK_INTERFACE="ens3"       # from: ip a
export PREFIX_LENGTH="24"
export GATEWAY="192.168.1.1"
export DNS_SERVER="192.168.1.10"      # bastion IP

# Master IPs — from: ip a
export MASTER1_IP="192.168.1.21"
export MASTER1_MAC="aa:bb:cc:dd:ee:01"   # from: ip link show ens3

export MASTER2_IP="192.168.1.22"
export MASTER2_MAC="aa:bb:cc:dd:ee:02"

export MASTER3_IP="192.168.1.23"
export MASTER3_MAC="aa:bb:cc:dd:ee:03"

# Workers — format: "hostname.cluster.domain:ip:mac"
WORKERS=(
    "worker.ocp.example.com:192.168.1.31:aa:bb:cc:dd:ee:04"
)

export MACHINE_NETWORK_CIDR="192.168.1.0/24"

# Generate SSH key on the bastion (if not already done)
#   ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa   (press Enter for no passphrase)
# Then paste the public key:
#   cat ~/.ssh/id_rsa.pub
export PULL_SECRET='...'
export SSH_KEY='ssh-rsa ...'   # paste output of: cat ~/.ssh/id_rsa.pub
```

Run the script:

```bash
sudo bash generate-agent-iso.sh
```

The ISO is written to `/root/agent/agent.x86_64.iso`.

---

## Step 4 — Boot and Monitor

1. Mount `agent.x86_64.iso` on all master and worker VMs.
2. Power on **all VMs at the same time**.
3. Watch progress from the bastion:

```bash
# Bootstrap phase
openshift-install agent wait-for bootstrap-complete \
    --dir /root/agent --log-level debug

# Full install
openshift-install agent wait-for install-complete \
    --dir /root/agent --log-level debug
```

---

## Step 5 — Verify

```bash
export KUBECONFIG=/root/agent/auth/kubeconfig

oc get nodes
oc get co
oc get clusterversion

# Approve pending CSRs (if workers stuck NotReady)
oc get csr | grep Pending
oc adm certificate approve <csr_name>

# Console URL and credentials
oc whoami --show-console
cat /root/agent/auth/kubeadmin-password
```
