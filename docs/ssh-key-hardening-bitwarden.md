# SSH Key Hardening + Bitwarden Backup — Design & Implementation Plan

Status: **Proposal for review** (no script changes made yet)
Target script: `get-hard.sh`
Branch: `claude/ssh-key-hardening-bitwarden-QqjuH`

This document proposes how to add optional **Bitwarden-backed SSH key handling**
to `vps-harden` without destabilising the existing interactive flow. It is a plan
only — the actual `get-hard.sh` functions are described, not yet written, so we
can agree the approach (and especially the security model) before touching the
script.

---

## 1. Goal

Let an operator, during hardening, optionally:

1. **Back up the server's SSH host keys** (`/etc/ssh/ssh_host_*`) into Bitwarden,
   so a rebuilt server can keep its host identity (no more "host key changed"
   warnings for clients), and
2. (optionally) **install a supplied admin public key** into `authorized_keys`
   in a controlled way, reinforcing the "only the public key ever lives on the
   server" model.

Everything must be **opt-in**, **non-fatal on failure**, and must not change the
behaviour of an existing run where the operator declines.

---

## 2. The key security distinction (must be respected in code)

There are two different SSH keys people conflate. The script must treat them
differently:

| Key type | Private key belongs on… | Should the hardening script handle the **private** key? |
|---|---|---|
| **Admin login key** (user authenticates with this) | The admin's own machine / their Bitwarden vault | **No.** The server should only ever receive the **public** key in `authorized_keys`. |
| **Server host key** (`/etc/ssh/ssh_host_*`) | The server itself | **Optionally back up.** Preserves host identity across rebuilds — but if leaked, an attacker can impersonate the server. Treat as sensitive. |

### Why we deliberately do *not* generate the admin key on the VPS

The tempting flow — *generate admin key on the VPS → upload to Bitwarden → delete
local copy* — means that during provisioning the box simultaneously holds the
private key, a Bitwarden session/token, and the tooling to push secrets. If the
box is already compromised or the installer was fetched over an untrusted path,
both the key and vault access can be exfiltrated.

**Decision:** `vps-harden` will never generate or upload an *admin* private key.
Admin keys are generated on a trusted machine; only the **public** key is passed
in. The only private material the script may touch is the **host** key, and only
when the operator explicitly opts in.

---

## 3. How this fits the current `get-hard.sh`

`get-hard.sh` is a single, linear, interactive Bash script. Functions are
defined top-to-bottom and invoked in a fixed order at the end of the file:

```
check_distro → setup_environment → display_banner → begin_log → create_swap →
update_upgrade → favored_packages → crypto_packages → add_user → collect_sshd →
prompt_rootlogin → disable_passauth → ufw_config → server_hardening →
google_auth → ksplice_install → motd_install → restart_sshd → install_complete
```

Relevant existing behaviour:

- `add_user()` already copies `/root/.ssh/authorized_keys` to the new sudo user
  if present (`get-hard.sh:399`).
- `disable_passauth()` already offers to require key-only login (`get-hard.sh:582`).
- `$SSHDFILE` is `/etc/ssh/sshd_config` (`get-hard.sh:86`).
- Logging convention: `... | tee -a "$LOGFILE"` with a timestamped prefix.
- Script is currently **Ubuntu-only** (16.04/18.04/20.04 per README) and uses
  `apt`, `ufw`, `fail2ban`.

The new work slots in as **two new opt-in functions** plus their call sites — it
does not restructure the script.

### Proposed new functions

| Function | Inserted after | Responsibility |
|---|---|---|
| `install_admin_key()` (optional) | `add_user` | If an admin public key is supplied (env `AUTHORIZED_KEY` or prompt), validate it with `ssh-keygen -l -f` and write it to the admin user's `authorized_keys` with correct perms. Public key only. |
| `bitwarden_backup()` | `restart_sshd` (i.e. after sshd is confirmed healthy) | Opt-in. If `bw` CLI + session are available, back up `/etc/ssh/ssh_host_*` to Bitwarden. Always non-fatal. |

`bitwarden_backup` runs **late** (after `restart_sshd`) so a Bitwarden hiccup can
never interfere with getting SSH back up — locking yourself out is the worst
outcome and must be impossible to trigger here.

---

## 4. Bitwarden integration details

### 4.1 Prerequisites (checked at runtime, never auto-installed silently)

`bitwarden_backup` should **detect, not assume**:

1. `command -v bw` — Bitwarden CLI present. If missing: log, skip, continue.
2. A usable session: `BW_SESSION` env var **or** the operator is prompted to run
   `bw unlock --raw`. The script must **not** hard-code or persist credentials.
3. `bw sync` succeeds.

If any precondition fails → print a clear note, log it, and continue hardening.
Backup is a convenience, never a gate.

### 4.2 Storage method — native SSH-key item, with attachment fallback

Bitwarden has a native **SSH key** item type (`type = 5`). We prefer it, but the
exact `sshKey` JSON schema should be read from the *installed* CLI template at
runtime rather than hard-coded, because the schema can change between CLI
versions.

**Pattern A — native SSH-key item (preferred):**

```bash
bw get template item --session "$BW_SESSION" \
  | jq \
    --arg name "vps-harden hostkey backup — $HOSTNAME $(date +%F)" \
    --arg priv "$(cat /etc/ssh/ssh_host_ed25519_key)" \
    --arg pub  "$(cat /etc/ssh/ssh_host_ed25519_key.pub)" \
    '.type = 5
     | .name = $name
     | .sshKey.privateKey = $priv
     | .sshKey.publicKey  = $pub' \
  | bw encode --session "$BW_SESSION" \
  | bw create item --session "$BW_SESSION"
```

**Pattern B — secure note + file attachments (fallback, schema-stable):**

```bash
ITEM_ID=$(
  bw get template item --session "$BW_SESSION" \
    | jq --arg name "vps-harden hostkey backup — $HOSTNAME" \
        '.type = 2 | .secureNote.type = 0 | .name = $name | .notes = "SSH host key backup"' \
    | bw encode --session "$BW_SESSION" \
    | bw create item --session "$BW_SESSION" | jq -r '.id'
)
for f in /etc/ssh/ssh_host_*; do
  bw create attachment --file "$f" --itemid "$ITEM_ID" --session "$BW_SESSION"
done
```

The implementation will **try A, fall back to B** if the SSH-key template fields
are absent in the installed CLI.

### 4.3 Note on unattended automation

For fully unattended fleets, **Bitwarden Secrets Manager** (machine accounts +
scoped access tokens) is a better fit than an interactive `bw` vault session.
This plan keeps the first version on the personal `bw` CLI (matches the script's
interactive nature); a Secrets Manager path can be a later follow-up and is
called out in §7.

---

## 5. Security considerations baked into the design

- **No admin private key ever generated or stored by the script.** Public key in,
  nothing private out. (§2)
- **Host-key backup is opt-in and clearly labelled as sensitive** — the prompt
  must state that a leaked host key allows server impersonation.
- **Non-fatal everywhere.** No Bitwarden step may abort hardening or block SSH.
- **No secrets in the log.** `$LOGFILE` currently captures a lot via `tee`. The
  Bitwarden function must route key material and session tokens to `/dev/null`,
  never to `$LOGFILE`, and `set +x` around any sensitive block.
- **Session hygiene.** If the script triggers `bw unlock`, it holds `BW_SESSION`
  only for the function's lifetime and unsets it afterward; it never writes it to
  disk.
- **Run after `restart_sshd`** so backup can never wedge SSH access.

---

## 6. Phased implementation

1. **Phase 1 — `install_admin_key()` (public key only).** Smallest, safest win;
   validates and installs a supplied pubkey. No Bitwarden dependency.
2. **Phase 2 — `bitwarden_backup()` host-key backup**, Pattern A with Pattern B
   fallback, all preconditions detected, fully non-fatal.
3. **Phase 3 — docs.** Update `README.md` with a short "Bitwarden host-key
   backup (optional)" section and prerequisites.
4. **Phase 4 (optional, later)** — Secrets Manager machine-account path for
   unattended fleets; LXC/non-Ubuntu awareness (see §7).

Each phase is independently reviewable and shippable.

---

## 7. Out of scope for the first version (explicitly deferred)

- **Local bootstrap script** that generates the admin key and stores the
  *private* key in Bitwarden on the operator's trusted machine. Valuable, but a
  separate deliverable from the on-server hardening script.
- **Distro/LXC profiles.** `get-hard.sh` is Ubuntu/`apt`-only today. Host-key
  backup itself is distro-agnostic, but firewall/sysctl/auditd hardening is not.
  A future refactor could split profiles (`debian-ubuntu`, `rhel-fedora`,
  `alpine`, `lxc-limited`, `vm-full`); for LXC specifically, sysctl/firewall/
  AppArmor are often host-managed and should be skipped on the guest.
- **Bitwarden Secrets Manager** integration (see §4.3).

---

## 8. Testing plan

- Run on a throwaway Ubuntu VPS with: (a) no `bw` installed, (b) `bw` installed
  but locked, (c) `bw` unlocked via `BW_SESSION` — confirm hardening completes in
  all three and only (c) produces a vault item.
- Confirm `$LOGFILE` contains **no** key material or session token after a run.
- Verify the created Bitwarden item round-trips: restore `ssh_host_*` from the
  vault to a fresh box and confirm the host key fingerprint matches.
- Confirm declining every new prompt yields byte-for-byte the same outcome as the
  current script (no behavioural regression).

---

## 9. Open questions for review

1. **Default placement of `install_admin_key`** — keep `add_user`'s existing
   "copy root's authorized_keys" behaviour, or have the new function supersede it
   when `AUTHORIZED_KEY` is supplied?
2. **Which host keys** — back up all `ssh_host_*` or only the modern
   `ed25519`/`rsa` pairs?
3. **Item naming / folder / collection** convention in Bitwarden (e.g.
   `vps-harden/<hostname>`), and should we update an existing item or always
   create a new one?
4. **Secrets Manager**: is unattended fleet use a near-term requirement, or is the
   interactive `bw` CLI sufficient for v1?
