#!/bin/bash

# =============================================================
# OpenShift Bastion Setup — DNS (BIND) + HAProxy
# =============================================================
# Masters are always 3.
# Workers: add as many as you need in the WORKERS array below.
#
# WORKER FORMAT: "hostname:ip"
# =============================================================

set -euo pipefail

# ----------------------------
# ENV VARIABLES — edit these
# ----------------------------
export BASTION_IP="190.170.31.41"
export BASTION_HOSTNAME="bastion-anish"
export DOMAIN="anishs.xyz"
export CLUSTER_NAME="ocp"

export MASTER1_IP="190.170.31.24"
export MASTER2_IP="190.170.31.56"
export MASTER3_IP="190.170.31.25"

export API_IP="190.170.31.41"
export INGRESS_IP="190.170.31.41"

export FORWARD_FILE="anish.for"
export REVERSE_FILE="anish.rev"

# ----------------------------
# WORKERS — add as many as needed
# FORMAT: "hostname:ip"
# ----------------------------
WORKERS=(
    "worker:190.170.31.18"
    # "worker-2:190.170.31.19"
    # "worker-3:190.170.31.20"
)

# =============================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================

SERIAL=$(date +%Y%m%d%S)
REVERSE_ZONE=$(echo "$BASTION_IP" | awk -F. '{print $3"."$2"."$1}')
BASTION_OCT=$(echo "$BASTION_IP" | awk -F. '{print $4}')
MASTER1_OCT=$(echo "$MASTER1_IP" | awk -F. '{print $4}')
MASTER2_OCT=$(echo "$MASTER2_IP" | awk -F. '{print $4}')
MASTER3_OCT=$(echo "$MASTER3_IP" | awk -F. '{print $4}')
API_OCT=$(echo     "$API_IP"     | awk -F. '{print $4}')

echo "============================================="
echo " OpenShift Bastion Setup"
echo "============================================="
echo " Domain         : $DOMAIN"
echo " Cluster        : $CLUSTER_NAME"
echo " Bastion        : $BASTION_HOSTNAME ($BASTION_IP)"
echo " API / API-INT  : $API_IP"
echo " Ingress *.apps : $INGRESS_IP"
echo " Master-1       : $MASTER1_IP"
echo " Master-2       : $MASTER2_IP"
echo " Master-3       : $MASTER3_IP"
echo " Workers        :"
for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    echo "   $WNAME -> $WIP"
done
echo " Reverse Zone   : $REVERSE_ZONE.in-addr.arpa"
echo " Forward File   : /var/named/$FORWARD_FILE"
echo " Reverse File   : /var/named/$REVERSE_FILE"
echo "============================================="
read -rp "Proceed? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

# =============================================================
# PART 1 — DNS (BIND)
# =============================================================

echo ""
echo "============================================="
echo " PART 1 — DNS Setup"
echo "============================================="

# ----------------------------
# STEP 1 — Install BIND
# ----------------------------
echo "[1/7] Installing BIND..."

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
    echo "  Repo file created."
fi

dnf install -y bind bind-utils

# ----------------------------
# STEP 2 — /etc/hosts + /etc/resolv.conf
# ----------------------------
echo "[2/7] Updating /etc/hosts..."
cat > /etc/hosts <<EOF
127.0.0.1   localhost localhost.localdomain
$BASTION_IP  $BASTION_HOSTNAME.$DOMAIN  $BASTION_HOSTNAME
EOF

echo "  Updating /etc/resolv.conf..."
cat > /etc/resolv.conf <<EOF
search $DOMAIN
nameserver 127.0.0.1
EOF

# ----------------------------
# STEP 3 — Add zones to named.conf
# ----------------------------
echo "[3/7] Adding zones to /etc/named.conf..."

sed -i "/^zone \"$DOMAIN\"/,/^};/d" /etc/named.conf
sed -i "/^zone \"$REVERSE_ZONE.in-addr.arpa\"/,/^};/d" /etc/named.conf

cat >> /etc/named.conf <<EOF

zone "$DOMAIN"
{
        type master;
        file "$FORWARD_FILE";
};

zone "$REVERSE_ZONE.in-addr.arpa"
{
        type master;
        file "$REVERSE_FILE";
};
EOF
echo "  Zones added to named.conf"

# ----------------------------
# STEP 4 — Copy template files
# ----------------------------
echo "[4/7] Copying zone file templates..."
cd /var/named
cp -p named.localhost "$FORWARD_FILE"
cp -p named.loopback  "$REVERSE_FILE"

# ----------------------------
# STEP 5 — Forward zone file
# ----------------------------
echo "[5/7] Writing forward zone file..."

cat > /var/named/"$FORWARD_FILE" <<EOF
\$TTL 1D
@   IN SOA $BASTION_HOSTNAME.$DOMAIN. root.$DOMAIN. (
        $SERIAL ; serial
        1H         ; refresh
        15M        ; retry
        1W         ; expire
        1D )       ; minimum

        IN NS  $BASTION_HOSTNAME.$DOMAIN.

$BASTION_HOSTNAME       IN A  $BASTION_IP

api.$CLUSTER_NAME       IN A  $API_IP
api-int.$CLUSTER_NAME   IN A  $API_IP

*.apps.$CLUSTER_NAME    IN A  $INGRESS_IP

master-1.$CLUSTER_NAME  IN A  $MASTER1_IP
master-2.$CLUSTER_NAME  IN A  $MASTER2_IP
master-3.$CLUSTER_NAME  IN A  $MASTER3_IP

EOF

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    echo "$WNAME.$CLUSTER_NAME   IN A  $WIP" >> /var/named/"$FORWARD_FILE"
done

# ----------------------------
# STEP 6 — Reverse zone file
# ----------------------------
echo "[6/7] Writing reverse zone file..."

cat > /var/named/"$REVERSE_FILE" <<EOF
\$TTL 1D
@   IN SOA $BASTION_HOSTNAME.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        1H
        15M
        1W
        1D )

        IN NS  $BASTION_HOSTNAME.$DOMAIN.

$BASTION_OCT  IN PTR  $BASTION_HOSTNAME.$DOMAIN.
$API_OCT      IN PTR  api.$CLUSTER_NAME.$DOMAIN.
$API_OCT      IN PTR  api-int.$CLUSTER_NAME.$DOMAIN.

$MASTER1_OCT  IN PTR  master-1.$CLUSTER_NAME.$DOMAIN.
$MASTER2_OCT  IN PTR  master-2.$CLUSTER_NAME.$DOMAIN.
$MASTER3_OCT  IN PTR  master-3.$CLUSTER_NAME.$DOMAIN.

EOF

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    WOCT=$(echo  "$WIP" | awk -F. '{print $4}')
    echo "$WOCT  IN PTR  $WNAME.$CLUSTER_NAME.$DOMAIN." >> /var/named/"$REVERSE_FILE"
done

# ----------------------------
# STEP 7 — named.conf options
# ----------------------------
echo "[7/7] Updating /etc/named.conf options..."

sed -i "s|listen-on port 53 {[^}]*};|listen-on port 53 { 127.0.0.1; $BASTION_IP; };|" /etc/named.conf
sed -i "s/allow-query\s*{[^}]*};/allow-query     { localhost; any; };/" /etc/named.conf

# ----------------------------
# Validate & Start BIND
# ----------------------------
echo ""
echo "Validating BIND configuration..."
named-checkconf && echo "  named.conf         : OK"
named-checkzone "$DOMAIN"                    /var/named/"$FORWARD_FILE" && echo "  Forward zone       : OK"
named-checkzone "$REVERSE_ZONE.in-addr.arpa" /var/named/"$REVERSE_FILE" && echo "  Reverse zone       : OK"

echo ""
echo "Starting named service..."
systemctl restart named

# ----------------------------
# DNS Verification
# ----------------------------
DNS_PASS=0
DNS_FAIL=0

check_forward() {
    local HOST=$1
    local EXPECTED=$2
    local RESULT
    RESULT=$(dig +short "$HOST")
    if [[ "$RESULT" == "$EXPECTED" ]]; then
        printf "  [PASS] %-42s -> %s\n" "$HOST" "$RESULT"
        DNS_PASS=$((DNS_PASS + 1))
    else
        printf "  [FAIL] %-42s -> got '%s', expected '%s'\n" "$HOST" "$RESULT" "$EXPECTED"
        DNS_FAIL=$((DNS_FAIL + 1))
    fi
}

check_reverse() {
    local IP=$1
    local EXPECTED=$2
    local RESULT
    RESULT=$(dig +short -x "$IP")
    if echo "$RESULT" | grep -q "^${EXPECTED}\.\?$"; then
        printf "  [PASS] %-20s -> %s\n" "$IP" "$(echo "$RESULT" | tr '\n' ' ')"
        DNS_PASS=$((DNS_PASS + 1))
    else
        printf "  [FAIL] %-20s -> got '%s', expected '%s'\n" "$IP" "$(echo "$RESULT" | tr '\n' ' ')" "$EXPECTED"
        DNS_FAIL=$((DNS_FAIL + 1))
    fi
}

echo ""
echo "============================================="
echo " Forward Lookups"
echo "============================================="
check_forward "$BASTION_HOSTNAME.$DOMAIN"        "$BASTION_IP"
check_forward "api.$CLUSTER_NAME.$DOMAIN"        "$API_IP"
check_forward "api-int.$CLUSTER_NAME.$DOMAIN"    "$API_IP"
check_forward "test.apps.$CLUSTER_NAME.$DOMAIN"  "$INGRESS_IP"
check_forward "master-1.$CLUSTER_NAME.$DOMAIN"   "$MASTER1_IP"
check_forward "master-2.$CLUSTER_NAME.$DOMAIN"   "$MASTER2_IP"
check_forward "master-3.$CLUSTER_NAME.$DOMAIN"   "$MASTER3_IP"

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    check_forward "$WNAME.$CLUSTER_NAME.$DOMAIN" "$WIP"
done

echo ""
echo "============================================="
echo " Reverse Lookups"
echo "============================================="
check_reverse "$BASTION_IP" "$BASTION_HOSTNAME.$DOMAIN"
check_reverse "$API_IP"     "api.$CLUSTER_NAME.$DOMAIN"
check_reverse "$MASTER1_IP" "master-1.$CLUSTER_NAME.$DOMAIN"
check_reverse "$MASTER2_IP" "master-2.$CLUSTER_NAME.$DOMAIN"
check_reverse "$MASTER3_IP" "master-3.$CLUSTER_NAME.$DOMAIN"

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    check_reverse "$WIP" "$WNAME.$CLUSTER_NAME.$DOMAIN"
done

echo ""
echo "============================================="
printf "  DNS Results: %d passed, %d failed\n" "$DNS_PASS" "$DNS_FAIL"
echo "============================================="

if [[ "$DNS_FAIL" -gt 0 ]]; then
    echo " ERROR: DNS checks failed. Fix before continuing."
    echo "============================================="
    exit 1
fi
echo " DNS Setup Complete!"
echo "============================================="

# =============================================================
# PART 2 — HAProxy
# =============================================================

echo ""
echo "============================================="
echo " PART 2 — HAProxy Setup"
echo "============================================="

# ----------------------------
# STEP 1 — Install HAProxy
# ----------------------------
echo "[1/3] Installing HAProxy..."
dnf install -y haproxy

# ----------------------------
# STEP 2 — Write haproxy.cfg
# ----------------------------
echo "[2/3] Writing /etc/haproxy/haproxy.cfg..."

cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout connect         10s
    timeout client          1m
    timeout server          1m

# -------------------------------------------------------------
# Kubernetes API — port 6443
# Used by: oc CLI, installer, all cluster nodes
# -------------------------------------------------------------
frontend api
    bind *:6443
    default_backend api_backend

backend api_backend
    balance roundrobin
    server master-1 $MASTER1_IP:6443 check
    server master-2 $MASTER2_IP:6443 check
    server master-3 $MASTER3_IP:6443 check

# -------------------------------------------------------------
# Machine Config Server — port 22623
# Used by: nodes to pull ignition configs during bootstrap
# -------------------------------------------------------------
frontend mcs
    bind *:22623
    default_backend mcs_backend

backend mcs_backend
    balance roundrobin
    server master-1 $MASTER1_IP:22623 check
    server master-2 $MASTER2_IP:22623 check
    server master-3 $MASTER3_IP:22623 check

# -------------------------------------------------------------
# HTTP Ingress — port 80
# Used by: app routes (http)
# -------------------------------------------------------------
frontend ingress_http
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance roundrobin
EOF

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    echo "    server $WNAME $WIP:80 check" >> /etc/haproxy/haproxy.cfg
done

cat >> /etc/haproxy/haproxy.cfg <<EOF

# -------------------------------------------------------------
# HTTPS Ingress — port 443
# Used by: app routes (tls)
# -------------------------------------------------------------
frontend ingress_https
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance roundrobin
EOF

for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    echo "    server $WNAME $WIP:443 check" >> /etc/haproxy/haproxy.cfg
done

# ----------------------------
# STEP 3 — Start & Enable
# ----------------------------
echo "[3/3] Starting HAProxy..."
setsebool -P haproxy_connect_any 1
systemctl enable --now haproxy

# ----------------------------
# HAProxy Verification
# ----------------------------
HA_PASS=0
HA_FAIL=0

echo ""
echo "============================================="
echo " HAProxy Verification"
echo "============================================="

for PORT in 6443 22623 80 443; do
    if ss -tlnp | grep -q ":$PORT "; then
        printf "  [PASS] Port %-6s is listening\n" "$PORT"
        HA_PASS=$((HA_PASS + 1))
    else
        printf "  [FAIL] Port %-6s is NOT listening\n" "$PORT"
        HA_FAIL=$((HA_FAIL + 1))
    fi
done

echo ""
echo "============================================="
printf "  HAProxy Results: %d passed, %d failed\n" "$HA_PASS" "$HA_FAIL"
echo "============================================="

if [[ "$HA_FAIL" -gt 0 ]]; then
    echo " WARNING: Some ports not listening. Check: systemctl status haproxy"
else
    echo " HAProxy Setup Complete!"
fi
echo "============================================="
echo ""
echo "============================================="
echo " Bastion Setup Complete!"
echo " DNS    : $(systemctl is-active named)"
echo " HAProxy: $(systemctl is-active haproxy)"
echo "============================================="
echo " Next step: Set up webserver for ignition files"
echo "============================================="
