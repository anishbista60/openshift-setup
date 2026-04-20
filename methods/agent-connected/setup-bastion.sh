#!/bin/bash

# =============================================================
# OpenShift Bastion Setup — DNS (BIND) + HAProxy
# =============================================================
# Flexible multi-subnet support:
#   - Bastion may live in a different subnet than masters/workers
#   - Script auto-detects all unique /24 reverse zones across
#     all IPs and creates a separate zone + PTR file for each
#
# WORKER FORMAT: "hostname:ip"
# =============================================================

set -euo pipefail

# ----------------------------
# ENV VARIABLES — edit these
# ----------------------------
export BASTION_IP="190.170.30.209"
export BASTION_HOSTNAME="bastion-anish"
export DOMAIN="anishs.xyz"
export CLUSTER_NAME="ocp"

export MASTER1_IP="190.170.41.76"
export MASTER2_IP="190.170.41.89"
export MASTER3_IP="190.170.41.74"

export API_IP="190.170.30.209"
export INGRESS_IP="190.170.30.209"

export FORWARD_FILE="anish.for"

# ----------------------------
# WORKERS — add as many as needed
# FORMAT: "hostname:ip"
# ----------------------------
WORKERS=(
    "worker-1:190.170.41.59"
    "worker-2:190.170.41.56"
    # "worker-3:190.170.31.20"
)

# =============================================================
# HELPER — derive /24 reverse zone from an IP
# e.g. 190.170.41.76 -> 41.170.190
# =============================================================
reverse_zone_of() {
    echo "$1" | awk -F. '{print $3"."$2"."$1}'
}

# =============================================================
# BUILD: reverse zone map
# Key   = zone string (e.g. "41.170.190")
# Value = zone file name (e.g. "anish.rev.41.170.190")
# =============================================================
declare -A ZONE_FILE_MAP   # zone_string -> filename
declare -A ZONE_PTR_MAP    # zone_string -> accumulated PTR lines

add_ptr() {
    local IP=$1
    local FQDN=$2
    local ZONE
    ZONE=$(reverse_zone_of "$IP")
    local OCT
    OCT=$(echo "$IP" | awk -F. '{print $4}')

    # Register zone -> filename if not seen yet
    if [[ -z "${ZONE_FILE_MAP[$ZONE]+_}" ]]; then
        ZONE_FILE_MAP[$ZONE]="anish.rev.${ZONE}"
        ZONE_PTR_MAP[$ZONE]=""
    fi

    # Append PTR record (allow duplicates — BIND handles them fine)
    ZONE_PTR_MAP[$ZONE]+="${OCT}  IN PTR  ${FQDN}.
"
}

# =============================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================

SERIAL=$(date +%Y%m%d%S)

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
echo "============================================="
read -rp "Proceed? (yes/no): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

# =============================================================
# PART 0 — Repository Setup
# =============================================================

echo ""
echo "============================================="
echo " PART 0 — Repository Setup"
echo "============================================="

if dnf repolist enabled 2>/dev/null | grep -q "^[a-zA-Z]"; then
    echo "  Repos already enabled — skipping repo setup."

elif subscription-manager status 2>/dev/null | grep -q "Overall Status: Current"; then
    # Already registered and entitled — repos just need enabling
    echo "  System is already registered with RHSM and subscription is current."
    echo "  Enabling repos..."
    subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms \
                               --enable=rhel-9-for-x86_64-appstream-rpms \
        && echo "  [OK] RHSM repos enabled." \
        || echo "  [WARN] Could not enable RHSM repos — check entitlements."

else
    echo "  No enabled repositories found."
    echo ""
    echo "  How would you like to enable package repositories?"
    echo "    1) Register with Red Hat Subscription Manager (RHSM) [Recommended for RHEL]"
    echo "    2) Use CentOS Stream 9 mirrors (no subscription required)"
    echo ""
    read -rp "  Enter choice (1 or 2): " REPO_CHOICE

    case "$REPO_CHOICE" in
        1)
            echo ""
            echo "  RHSM Registration"
            echo "  -----------------"

            # Check if already registered (even if repos not yet enabled)
            if subscription-manager identity 2>/dev/null | grep -q "system identity"; then
                REGISTERED_ORG=$(subscription-manager identity 2>/dev/null | grep "org ID" | awk -F: '{print $2}' | xargs)
                echo "  System is already registered (org: ${REGISTERED_ORG:-unknown})."
                echo "  Skipping registration — enabling repos only."
            else
                echo "  Choose registration method:"
                echo "    a) Username + Password"
                echo "    b) Activation Key + Org ID"
                echo ""
                read -rp "  Enter choice (a or b): " RHSM_METHOD

                if [[ "$RHSM_METHOD" == "a" ]]; then
                    read -rp "  Red Hat username: " RHSM_USER
                    read -rsp "  Red Hat password: " RHSM_PASS
                    echo ""
                    subscription-manager register --username "$RHSM_USER" --password "$RHSM_PASS" --force
                elif [[ "$RHSM_METHOD" == "b" ]]; then
                    read -rp "  Activation Key: " RHSM_KEY
                    read -rp "  Org ID:         " RHSM_ORG
                    subscription-manager register --activationkey "$RHSM_KEY" --org "$RHSM_ORG"
                else
                    echo "  Invalid choice. Exiting."
                    exit 1
                fi
            fi

            ;;

        2)
            echo "  Adding CentOS Stream 9 mirror repos..."
            cat > /etc/yum.repos.d/centos-stream9.repo <<'REPO'
[cs9-baseos]
name=CentOS Stream 9 - BaseOS
baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/
gpgcheck=0
enabled=1

[cs9-appstream]
name=CentOS Stream 9 - AppStream
baseurl=https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/
gpgcheck=0
enabled=1
REPO
            echo "  [OK] CentOS Stream 9 repos added."
            ;;

        *)
            echo "  Invalid choice. Exiting."
            exit 1
            ;;
    esac
fi

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
# STEP 3 — Build PTR map across all IPs
# ----------------------------
echo "[3/7] Detecting reverse zones across all subnets..."

# Bastion subnet
add_ptr "$BASTION_IP"  "$BASTION_HOSTNAME.$DOMAIN"

# API / Ingress (may be same subnet as bastion, or different)
add_ptr "$API_IP"      "api.$CLUSTER_NAME.$DOMAIN"
add_ptr "$API_IP"      "api-int.$CLUSTER_NAME.$DOMAIN"

# Masters
add_ptr "$MASTER1_IP"  "master-1.$CLUSTER_NAME.$DOMAIN"
add_ptr "$MASTER2_IP"  "master-2.$CLUSTER_NAME.$DOMAIN"
add_ptr "$MASTER3_IP"  "master-3.$CLUSTER_NAME.$DOMAIN"

# Workers
for W in "${WORKERS[@]}"; do
    WNAME=$(echo "$W" | cut -d: -f1)
    WIP=$(echo   "$W" | cut -d: -f2)
    add_ptr "$WIP" "$WNAME.$CLUSTER_NAME.$DOMAIN"
done

echo "  Detected reverse zones:"
for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    echo "    $ZONE.in-addr.arpa  ->  /var/named/${ZONE_FILE_MAP[$ZONE]}"
done

# ----------------------------
# STEP 4 — Add zones to named.conf
# ----------------------------
echo "[4/7] Adding zones to /etc/named.conf..."

# Remove old forward zone entry if present
sed -i "/^zone \"$DOMAIN\"/,/^};/d" /etc/named.conf

# Remove all old reverse zone entries managed by this script
for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    sed -i "/^zone \"$ZONE.in-addr.arpa\"/,/^};/d" /etc/named.conf
done

# Add forward zone
cat >> /etc/named.conf <<EOF

zone "$DOMAIN"
{
        type master;
        file "$FORWARD_FILE";
};
EOF

# Add one reverse zone block per detected subnet
for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    REVFILE="${ZONE_FILE_MAP[$ZONE]}"
    cat >> /etc/named.conf <<EOF

zone "$ZONE.in-addr.arpa"
{
        type master;
        file "$REVFILE";
};
EOF
done

echo "  Zones added to named.conf."

# ----------------------------
# STEP 5 — Write forward zone file
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
# STEP 6 — Write one reverse zone file per subnet
# ----------------------------
echo "[6/7] Writing reverse zone files..."

for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    REVFILE="/var/named/${ZONE_FILE_MAP[$ZONE]}"
    echo "  Writing $REVFILE  ($ZONE.in-addr.arpa)"

    cat > "$REVFILE" <<EOF
\$TTL 1D
@   IN SOA $BASTION_HOSTNAME.$DOMAIN. root.$DOMAIN. (
        $SERIAL
        1H
        15M
        1W
        1D )

        IN NS  $BASTION_HOSTNAME.$DOMAIN.

${ZONE_PTR_MAP[$ZONE]}
EOF
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
named-checkzone "$DOMAIN" /var/named/"$FORWARD_FILE" && echo "  Forward zone       : OK"

for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    REVFILE="/var/named/${ZONE_FILE_MAP[$ZONE]}"
    named-checkzone "$ZONE.in-addr.arpa" "$REVFILE" \
        && echo "  Reverse zone [$ZONE] : OK"
done

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
    if echo "$RESULT" | grep -qE "^${EXPECTED}\.?$"; then
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

echo "[1/3] Installing HAProxy..."
dnf install -y haproxy

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
echo " Reverse zones created:"
for ZONE in "${!ZONE_FILE_MAP[@]}"; do
    echo "   $ZONE.in-addr.arpa  ->  /var/named/${ZONE_FILE_MAP[$ZONE]}"
done
echo "============================================="
echo " Next step: Set up webserver for ignition files"
echo "============================================="
