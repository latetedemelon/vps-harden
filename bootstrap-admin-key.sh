#!/usr/bin/env bash
#
# bootstrap-admin-key.sh — generate an admin SSH key on a TRUSTED machine,
# store the PRIVATE key in Bitwarden locally, and print only the PUBLIC key to
# hand to vps-lockdown.sh (--admin-key-file). The private key never touches the
# server: this is the safe inverse of generating keys on the box being hardened.
#
# Usage:
#   ./bootstrap-admin-key.sh [-n NAME] [-d DIR] [--no-bitwarden]
#
#   -n NAME   key/item name (default: admin-<host>-<date>)
#   -d DIR    where to write the keypair (default: ~/.ssh)
#   --no-bitwarden   skip storing the private key in Bitwarden
#
# Then on the target:
#   sudo ./vps-lockdown.sh --admin-key-file <NAME>.pub --user youradmin
#
set -euo pipefail

NAME="admin-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d)"
DIR="$HOME/.ssh"
USE_BW="yes"

while [ $# -gt 0 ]; do
    case "$1" in
        -n) shift; NAME="$1" ;;
        -d) shift; DIR="$1" ;;
        --no-bitwarden) USE_BW="no" ;;
        -h|--help) grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required." >&2; exit 1; }

KEY="$DIR/$NAME"
mkdir -p "$DIR"; chmod 700 "$DIR"

if [ -e "$KEY" ]; then
    echo "Key already exists at $KEY; refusing to overwrite." >&2
    exit 1
fi

echo "Generating ed25519 admin key: $KEY"
ssh-keygen -t ed25519 -a 100 -f "$KEY" -C "$NAME" -N ""

PUB="$(cat "$KEY.pub")"

# Store the PRIVATE key in Bitwarden (local, trusted machine only).
if [ "$USE_BW" = "yes" ] && command -v bw >/dev/null 2>&1; then
    SESS="${BW_SESSION:-}"
    if [ -z "$SESS" ]; then SESS="$(bw unlock --raw)"; fi
    if [ -n "$SESS" ]; then
        bw sync --session "$SESS" >/dev/null 2>&1 || true
        # Prefer a native SSH-key item (type 5); fall back to a secure note if the
        # installed CLI template lacks the sshKey fields.
        if bw get template item --session "$SESS" 2>/dev/null | jq -e 'has("sshKey")' >/dev/null 2>&1; then
            bw get template item --session "$SESS" \
              | jq --arg n "$NAME" --arg priv "$(cat "$KEY")" --arg pub "$PUB" \
                   '.type=5 | .name=$n | .sshKey.privateKey=$priv | .sshKey.publicKey=$pub' \
              | bw encode | bw create item --session "$SESS" >/dev/null \
              && echo "Stored private key in Bitwarden as SSH-key item '$NAME'."
        else
            ID="$(bw get template item --session "$SESS" \
                    | jq --arg n "$NAME" '.type=2 | .secureNote.type=0 | .name=$n | .notes="admin SSH key"' \
                    | bw encode | bw create item --session "$SESS" | jq -r '.id')"
            bw create attachment --file "$KEY"     --itemid "$ID" --session "$SESS" >/dev/null
            bw create attachment --file "$KEY.pub" --itemid "$ID" --session "$SESS" >/dev/null
            echo "Stored private+public key as attachments on item '$NAME'."
        fi
    else
        echo "No Bitwarden session; private key left only at $KEY (store it yourself)." >&2
    fi
elif [ "$USE_BW" = "yes" ]; then
    echo "Bitwarden CLI (bw) not found; private key left only at $KEY (store it yourself)." >&2
fi

echo
echo "Public key (give this to the server, never the private key):"
echo "  $PUB"
echo
echo "On the target server, run:"
echo "  sudo ./vps-lockdown.sh --admin-key-file '$KEY.pub' --user <youradmin>"
