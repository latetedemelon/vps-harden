# VPS Hardening Suite — Design & Implementation Plan

Status: **Proposal for review** (no script changes made yet)
Target script: `get-hard.sh` (+ `vps-audit.sh` as the verification companion)
Branch: `claude/ssh-key-hardening-bitwarden-QqjuH`

This document started as a plan for **Bitwarden-backed SSH key handling** and has,
per review, grown into the agreed scope for a best-of-breed hardening suite. **All
of the following are now in scope** (sequenced, not dropped):

1. Bitwarden-backed SSH key handling (§1–§5) — the original pillar.
2. **Backout / rollback** as a first-class feature, so any change can be undone
   and a failed step self-heals (§7.1).
3. **Read-only audit** integration via `vps-audit.sh` — a "harden, then verify"
   loop, with a dry-run/audit mode (§7.2).
4. **Non-interactive automation** (CLI flags + Secrets Manager) for unattended
   fleets (§7.3).
5. **Cross-distro + LXC awareness and CIS-depth hardening** as later phases
   (§7.4), drawn from the best-of-breed review (§9).

It remains a plan only — functions are described, not yet written, so we can agree
the approach (especially the security model and the rollback contract) before
touching the script.

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
The interactive `bw` CLI is the default path (matches the script's interactive
nature); the Secrets Manager machine-account path is now in scope as the
unattended-automation profile (§7.3).

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

## 6. Phased implementation (delivery order — all phases in scope)

Phases are a *sequencing* of the agreed scope, each independently reviewable and
shippable. Nothing here is dropped; later phases are simply later.

1. **Phase 1 — Backout foundation (§7.1).** A `change_record` + `revert` helper
   so every subsequent mutating step is backed up and reversible. Built first
   because everything else depends on it for safety.
2. **Phase 2 — `install_admin_key()` (public key only).** Validate and install a
   supplied pubkey. No Bitwarden dependency.
3. **Phase 3 — `bitwarden_backup()` host-key backup**, Pattern A with Pattern B
   fallback, all preconditions detected, fully non-fatal.
4. **Phase 4 — Audit integration (§7.2).** Wire `vps-audit.sh` as a post-harden
   verification gate; add a `--audit`/read-only dry-run mode.
5. **Phase 5 — Non-interactive automation (§7.3).** CLI flags (`--admin-key`,
   `--ssh-port`, `--yes`, `--rollback`) and a Secrets Manager profile.
6. **Phase 6 — Cross-distro + LXC + CIS depth (§7.4).** Distro/service
   abstraction, LXC detection, and the deeper konstruktoid-style controls.
7. **Phase 7 — docs.** Update `README.md` for each capability as it lands.

---

## 7. Now in full scope (was previously deferred)

### 7.1 Backout / rollback (first-class)

Every change the script makes must be **recorded and reversible**. Adopt the
pratiktri pattern (timestamped backups + revert functions) and generalise it:

- A `change_record <path>` helper copies any file to
  `<path>.vps-harden.<timestamp>.bak` **before** first modification, and appends
  the original path to a manifest at `/var/backups/vps-harden/<run-id>/manifest`.
- For non-file changes (package installs, `ufw enable`, service state) record an
  inverse action in the same manifest (e.g. `ufw disable`, `apt remove`).
- A `--rollback [run-id]` mode replays the manifest in reverse: restore files
  from `.bak`, run inverse actions, then `sshd -t` and reload. Defaults to the
  most recent run.
- Each step runs under a `trap` so a mid-step failure triggers an automatic
  revert of *that* step and a clear prompt, instead of leaving a half-applied
  change. This is the safety net that makes aggressive SSH/firewall changes safe.
- Extends — not replaces — the existing `sshd_config` backup (`get-hard.sh:464`).

### 7.2 Read-only audit integration

`vps-audit.sh` already performs 53 PASS/WARN/FAIL checks and changes nothing —
keep it exactly as a read-only tool and wire it into the workflow:

- **Post-harden gate:** after `get-hard.sh` finishes (and after rollback), run
  `vps-audit.sh` and surface the summary, so the operator sees independent
  confirmation that root login/password auth/port/firewall/updates landed.
- **Dry-run / `--audit` mode in `get-hard.sh`:** a read-only pass that reports
  what *would* change without writing anything — mirrors the audit tool's
  philosophy and lets operators preview before committing.
- **Machine-readable output (cross-repo, `vps-audit`):** add a `--json` (and
  meaningful exit code) mode to `vps-audit.sh` so the harden script — or CI — can
  consume results programmatically and fail a run if a critical check regresses.
  This is a small companion change planned on the `vps-audit` repo's matching
  branch.

### 7.3 Non-interactive automation

- **CLI flags** (pratiktri-style): `--admin-key`, `--ssh-port`, `--user`,
  `--yes`, `--audit`, `--rollback` so the same script serves guided *and*
  unattended runs. Interactive prompts remain the default when flags are absent.
- **Bitwarden Secrets Manager** profile (machine account + scoped access token)
  for fleet automation, selected when a token is present instead of an
  interactive `bw` session (§4.3).
- **Local bootstrap script** (operator's trusted machine): generate the admin
  ed25519 key, store the **private** key in Bitwarden locally, and pass only the
  **public** key to `get-hard.sh` — the safe inverse of pratiktri's on-server
  key generation (§2, §9).

### 7.4 Cross-distro, LXC awareness, and CIS-depth hardening

- **Distro/service abstraction** (pratiktri): detect `apt`/`dnf`/`zypper`/
  `pacman` and systemd/sysvinit so the suite runs beyond Ubuntu. Split into
  profiles: `debian-ubuntu`, `rhel-fedora`, `alpine`, `lxc-limited`, `vm-full`.
- **LXC/LXD detection** (konstruktoid): on containers, skip controls that belong
  on the host (sysctl, firewall, AppArmor) instead of failing.
- **CIS-depth controls** (konstruktoid), added incrementally and each gated +
  reversible via §7.1: auditd, AppArmor enforce, sysctl hardening, AIDE, usbguard,
  kernel module/filesystem disabling, PAM/umask, no-exec mounts. Each is
  validated by the audit gate (§7.2).

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
- **Backout (§7.1):** after a full run, `--rollback` restores files from the
  manifest, reverses inverse actions, and `vps-audit.sh` afterward shows the box
  back at its pre-harden baseline. Also force a mid-step failure and confirm the
  `trap` auto-reverts just that step, leaving SSH reachable.
- **Audit gate (§7.2):** `vps-audit.sh` run after hardening reports the expected
  PASS results; `--audit` dry-run mode writes nothing (verify with no file mtime
  changes); `--json` output parses and returns a non-zero exit on a seeded
  critical regression.
- **Non-interactive (§7.3):** a fully flag-driven run (`--admin-key … --ssh-port
  … --yes`) completes with no prompts and matches the interactive result.

---

## 9. Best-of-breed synthesis (4 reference scripts)

Per review feedback, the approach was re-evaluated against four existing
hardening scripts plus the audit companion in this org. The goal is to take the
strongest ideas from each rather than reinvent them.

### Scripts reviewed

| # | Script | Style | Distro scope | Notable strengths | Notable gaps |
|---|---|---|---|---|---|
| 1 | **`vps-harden/get-hard.sh`** (this repo, akcryptoguy) | Interactive, monolithic | Ubuntu only | Friendly guided flow; swap; Google Authenticator 2FA; ksplice; MOTD; backs up `sshd_config`; logs to `/var/log/server_hardening.log` | Ubuntu-only; one long file; copies root's `authorized_keys`; no key validation; no rollback |
| 2 | **`AMega/VPS-Server-Hardening`** (cited ancestor) | Interactive, simple | Ubuntu only | Clear minimal baseline (user, SSH port, UFW, MOTD) | fail2ban only half-implemented; least complete; largely superseded by #1 |
| 3 | **`konstruktoid/hardening`** (`ubuntu.sh`) | Modular, config-driven, idempotent | Ubuntu LTS | CIS-grade depth: auditd, AppArmor enforce, AIDE+timer, rkhunter, usbguard, sysctl, disabled kernel modules/filesystems, SUID/umask/PAM limits, no-exec mounts; UFW with admin-IP allowlist + SSH group restriction; **LXC/LXD detection**; sources `scripts/*` with a `.cfg` | Heavyweight; opinionated; not interactive/newbie-oriented |
| 4 | **`pratiktri/server_init_harden`** (`init-linux-harden.sh`) | POSIX, non-interactive CLI | Debian/Ubuntu/RHEL/Fedora/SUSE/Arch/**FreeBSD** | Cross-distro via service/pkg abstraction; CLI flags (`-u`, `-r`); timestamped backups **with revert functions**; `sshd -t` validation before restart; fail2ban `recidive` jail + ignores server's own IP | **Generates the SSH keypair on the server and echoes the private key to the console and log file before deleting it** — the exact anti-pattern this design rejects (see §2) |
| — | **`vps-audit/vps-audit.sh`** (companion, ex-vernu) | Read-only, 53 PASS/WARN/FAIL checks | Linux | Independent verification of SSH/root/password/port/firewall/updates; handles `Include` override dirs | Audits, does not change anything (by design) |

### What to adopt from each

- **From konstruktoid:** config-file-driven + modular sourcing for *idempotency*;
  the deep-hardening backlog (auditd, AppArmor, sysctl, AIDE, usbguard, kernel
  module/filesystem disabling, PAM/umask); and **LXC/LXD detection** — which
  directly validates the LXC-profile work now in scope at §7.4.
- **From pratiktri:** **non-interactive CLI flags** (essential for unattended/
  Bitwarden automation), the **multi-distro service/package abstraction**, and
  **timestamped backups paired with revert functions** so a failed step rolls
  back. Its `sshd -t`-before-restart is the right safety gate (#1 already does a
  variant). Its fail2ban `recidive` + ignore-own-IP jail is a cheap win.
- **From pratiktri (as a cautionary tale):** its private-key handling is exactly
  why §2 forbids the script from ever generating or emitting an admin *private*
  key, and why §5 forbids writing key material to `$LOGFILE`. This is the single
  most important "do the opposite of this" lesson of the comparison.
- **From `get-hard.sh` (keep):** the guided interactive UX, swap setup, optional
  2FA, MOTD, and `sshd_config` backup — these make it approachable for newcomers,
  which is this project's audience.
- **From AMega:** nothing net-new; it is the minimal ancestor of #1.
- **From vps-audit:** treat its 53 checks as **acceptance criteria** — run
  `vps-audit.sh` after hardening to confirm SSH root/password/port and firewall
  land as intended. "Harden, then audit" closes the loop.

### Resulting recommendation (all of this is now in scope)

Keep `get-hard.sh`'s approachable interactive flow as the base, and build out the
full suite in the delivery order of §6:

1. **Backout/rollback first** (§7.1, pratiktri) — every mutating step backed up
   and reversible, extending the existing `sshd_config` backup, so a bad step
   self-heals instead of locking the operator out.
2. **Bitwarden + admin-pubkey work** (§3–§6) — security model unchanged; the
   comparison reinforced it.
3. **Read-only audit as the verification gate** (§7.2, vps-audit) — "harden, then
   audit," plus a `--audit` dry-run and a `--json` mode on `vps-audit.sh`.
4. **Non-interactive automation** (§7.3, pratiktri) — CLI flags + Secrets Manager
   for unattended runs, plus the local-bootstrap key-generation script.
5. **Cross-distro/LXC + CIS depth** (§7.4, konstruktoid/pratiktri), each control
   gated and reversible and validated by the audit gate.

Sequenced so each phase ships and is reviewable on its own, with safety
(backout + audit) landing before the aggressive changes that need it.

## 10. Open questions for review

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
5. **Rollback granularity (§7.1):** is per-step auto-revert-on-failure enough, or
   do you also want a full `--rollback` that returns the box to its pre-harden
   state in one command? (Plan currently includes both.)
6. **Audit coupling (§7.2):** should a failing `vps-audit.sh` critical check make
   a hardening run exit non-zero (CI-style gate), or only warn? And do you want
   the `--json` mode added to `vps-audit` in the same PR series or its own?
7. **Distro priority (§7.4):** after Ubuntu/Debian, which distro family next —
   RHEL/Fedora or Alpine — and is LXC support needed early or late?
