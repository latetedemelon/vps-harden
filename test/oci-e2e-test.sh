#!/usr/bin/env bash
#
# oci-e2e-test.sh — end-to-end validation of vps-lockdown.sh on a throwaway
# Oracle Cloud Always-Free instance. Provisions a dedicated VCN + instance, runs
# the hardening suite + the vps-audit gate over SSH, collects the logs, and tears
# everything down.
#
# REQUIREMENTS (this is why it is NOT run in the build sandbox):
#   - `oci` CLI installed and configured (a working ~/.oci/config profile)
#   - OUTBOUND SSH (port 22) egress from wherever you run this
#   - ssh-keygen, ssh, scp, jq
#
# USAGE:
#   export OCI_COMPARTMENT=ocid1.tenancy.oc1..xxxx   # or a compartment OCID
#   export OCI_CLI_PROFILE=DEFAULT                    # optional
#   ./test/oci-e2e-test.sh
#
# It is deliberately conservative: it keeps SSH on port 22 (so the run cannot lock
# itself out of the test box), tags every resource `vps-harden-e2e-*`, and removes
# them on exit. Always-Free shapes only — no cost if your free tier has room.
#
set -uo pipefail

OCI="${OCI:-oci}"
COMPARTMENT="${OCI_COMPARTMENT:?set OCI_COMPARTMENT to a tenancy/compartment OCID}"
PROFILE_ARG=(); [ -n "${OCI_CLI_PROFILE:-}" ] && PROFILE_ARG=(--profile "$OCI_CLI_PROFILE")
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VPS_AUDIT="${VPS_AUDIT:-$REPO_ROOT/../vps-audit/vps-audit.sh}"
WORK="$(mktemp -d)"; echo "work dir: $WORK"
STATE="$WORK/state.env"; : > "$STATE"

oci() { command "$OCI" "${PROFILE_ARG[@]}" "$@"; }

cleanup() {
    echo "=== teardown ==="
    # shellcheck disable=SC1090
    source "$STATE" 2>/dev/null || true
    [ -n "${INST:-}" ]   && oci compute instance terminate --instance-id "$INST" --force --wait-for-state TERMINATED >/dev/null 2>&1 && echo " terminated instance"
    [ -n "${SUBNET:-}" ] && oci network subnet delete --subnet-id "$SUBNET" --force --wait-for-state TERMINATED >/dev/null 2>&1
    [ -n "${IGW:-}" ]    && oci network internet-gateway delete --ig-id "$IGW" --force --wait-for-state TERMINATED >/dev/null 2>&1
    [ -n "${RT:-}" ]     && oci network route-table delete --rt-id "$RT" --force --wait-for-state TERMINATED >/dev/null 2>&1
    [ -n "${SL:-}" ]     && oci network security-list delete --security-list-id "$SL" --force --wait-for-state TERMINATED >/dev/null 2>&1
    [ -n "${VCN:-}" ]    && oci network vcn delete --vcn-id "$VCN" --force --wait-for-state TERMINATED >/dev/null 2>&1 && echo " deleted VCN"
    rm -rf "$WORK"
    echo " done."
}
trap cleanup EXIT

echo "=== preflight ==="
for t in ssh ssh-keygen scp jq; do command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }; done
[ -f "$VPS_AUDIT" ] || { echo "vps-audit.sh not found at $VPS_AUDIT (set VPS_AUDIT=...)"; exit 1; }
# confirm SSH egress actually works from here, else this test cannot run
timeout 10 bash -c 'exec 3<>/dev/tcp/github.com/22' 2>/dev/null || { echo "ERROR: no outbound port 22 from here; run this where SSH egress is allowed."; exit 1; }
oci iam region-subscription list >/dev/null || { echo "ERROR: oci auth failed"; exit 1; }

AD="$(oci iam availability-domain list --compartment-id "$COMPARTMENT" --query 'data[0].name' --raw-output)"
REGION="$(oci iam region-subscription list --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output)"
echo "AD=$AD region=$REGION"

echo "=== ssh key ==="
ssh-keygen -t ed25519 -f "$WORK/key" -N "" -C vps-harden-e2e >/dev/null

echo "=== network ==="
VCN=$(oci network vcn create --compartment-id "$COMPARTMENT" --cidr-blocks '["10.0.0.0/16"]' --display-name vps-harden-e2e-vcn --dns-label vpshe2e --wait-for-state AVAILABLE --query 'data.id' --raw-output); echo "VCN=$VCN" >>"$STATE"
IGW=$(oci network internet-gateway create --compartment-id "$COMPARTMENT" --vcn-id "$VCN" --is-enabled true --display-name vps-harden-e2e-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output); echo "IGW=$IGW" >>"$STATE"
RT=$(oci network route-table create --compartment-id "$COMPARTMENT" --vcn-id "$VCN" --display-name vps-harden-e2e-rt --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" --wait-for-state AVAILABLE --query 'data.id' --raw-output); echo "RT=$RT" >>"$STATE"
SL=$(oci network security-list create --compartment-id "$COMPARTMENT" --vcn-id "$VCN" --display-name vps-harden-e2e-sl --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]' --wait-for-state AVAILABLE --query 'data.id' --raw-output); echo "SL=$SL" >>"$STATE"
SUBNET=$(oci network subnet create --compartment-id "$COMPARTMENT" --vcn-id "$VCN" --cidr-block "10.0.0.0/24" --display-name vps-harden-e2e-subnet --dns-label sub --route-table-id "$RT" --security-list-ids "[\"$SL\"]" --prohibit-public-ip-on-vnic false --wait-for-state AVAILABLE --query 'data.id' --raw-output); echo "SUBNET=$SUBNET" >>"$STATE"

echo "=== launch instance (Always-Free ARM Ubuntu 22.04) ==="
IMG=$(oci compute image list --compartment-id "$COMPARTMENT" --operating-system "Canonical Ubuntu" --operating-system-version "22.04" --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output)
INST=$(oci compute instance launch --availability-domain "$AD" --compartment-id "$COMPARTMENT" --shape "VM.Standard.A1.Flex" --shape-config '{"ocpus":1,"memoryInGBs":6}' --display-name vps-harden-e2e-vm --image-id "$IMG" --subnet-id "$SUBNET" --assign-public-ip true --ssh-authorized-keys-file "$WORK/key.pub" --wait-for-state RUNNING --query 'data.id' --raw-output); echo "INST=$INST" >>"$STATE"
IP=$(oci compute instance list-vnics --instance-id "$INST" --query 'data[0]."public-ip"' --raw-output); echo "IP=$IP"

echo "=== wait for SSH ==="
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -i $WORK/key ubuntu@$IP"
for i in $(seq 1 40); do $SSH true 2>/dev/null && break; sleep 8; [ "$i" = 40 ] && { echo "SSH never came up"; exit 1; }; done
echo "SSH up: $($SSH '. /etc/os-release; echo $PRETTY_NAME $(uname -m)')"

echo "=== copy suite ==="
tar czf "$WORK/suite.tgz" -C "$REPO_ROOT" --exclude='.git' --exclude='media' --exclude='*.png' .
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$WORK/key" "$WORK/suite.tgz" "$VPS_AUDIT" "$WORK/key.pub" ubuntu@"$IP":/home/ubuntu/ >/dev/null

echo "=== run hardening (keeps port 22, non-interactive) + audit ==="
$SSH 'set -x; mkdir -p ~/suite && tar xzf ~/suite.tgz -C ~/suite && cd ~/suite &&
  sudo AUTHORIZED_KEY="$(cat ~/key.pub)" bash vps-lockdown.sh --yes --ssh-port 22 --user testadmin --admin-key-file ~/key.pub; echo "LOCKDOWN_EXIT=$?";
  sudo bash ~/vps-audit.sh --json > /tmp/audit.json 2>/dev/null; echo "AUDIT_EXIT=$?"; echo "--- audit summary ---"; jq "{critical_fails,total_fails}" /tmp/audit.json' 2>&1 | tee "$WORK/run.log"

echo
echo "=== RESULT ==="
grep -E 'LOCKDOWN_EXIT|AUDIT_EXIT|critical_fails' "$WORK/run.log" || true
echo "Full log: $WORK/run.log (kept until this script exits)"
echo "Review it above; teardown runs on exit."
