# VPS Hardening Suite — Design & Implementation Plan

Status: **Phases 1–4 + Phase 5 (CLI/non-interactive) implemented** — container
guard, per-step backout, `install_admin_key()`, optional `bitwarden_backup()`, the
`vps-audit` audit gate, and a non-interactive CLI flag parser are in
`vps-lockdown.sh` (with the `vps-audit --json` companion in
[vps-audit#3](https://github.com/latetedemelon/vps-audit/pull/3)). Remaining in
Phase 5: Secrets Manager profile + local key-bootstrap script. Phases 6–7 planned.
Target script: `vps-lockdown.sh` (+ `vps-audit.sh` as the verification companion)
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

## 0. Core principle: Bitwarden is optional

**`vps-lockdown.sh` must fully harden a server with no Bitwarden present.** This is
a hard requirement, not a nicety:

- The core flow (user, SSH config, firewall, updates, fail2ban, sysctl, backout,
  audit) depends on **no** Bitwarden component — no `bw` CLI, no `jq`, no vault,
  no session, no Secrets Manager token.
- Bitwarden adds exactly one optional capability: **host-key backup** (§4), plus a
  later optional Secrets Manager path for unattended automation (§7.3).
- If `bw`/`jq` is missing, or the vault is locked, or any Bitwarden call fails, the
  function **logs, skips, and continues** — the run still succeeds and exits 0 for
  reasons unrelated to Bitwarden. Bitwarden is never on the critical path and never
  a gate.
- `jq` and `bw` are therefore **soft dependencies**, checked only inside the
  Bitwarden function (`command -v`), never required at startup.

Everything below treats Bitwarden as a bolt-on to an already-complete hardening
tool.

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

## 3. How this fits the current `vps-lockdown.sh`

`vps-lockdown.sh` is a single, linear, interactive Bash script. Functions are
defined top-to-bottom and invoked in a fixed order at the end of the file:

```
check_distro → setup_environment → display_banner → begin_log → create_swap →
update_upgrade → favored_packages → crypto_packages → add_user → collect_sshd →
prompt_rootlogin → disable_passauth → ufw_config → server_hardening →
google_auth → ksplice_install → motd_install → restart_sshd → install_complete
```

Relevant existing behaviour:

- `add_user()` already copies `/root/.ssh/authorized_keys` to the new sudo user
  if present (`vps-lockdown.sh:399`).
- `disable_passauth()` already offers to require key-only login (`vps-lockdown.sh:582`).
- `$SSHDFILE` is `/etc/ssh/sshd_config` (`vps-lockdown.sh:86`).
- Logging convention: `... | tee -a "$LOGFILE"` with a timestamped prefix.
- Script is currently **Ubuntu-only** (16.04/18.04/20.04 per README) and uses
  `apt`, `ufw`, `fail2ban`.

The new work slots in as **two new opt-in functions** plus their call sites — it
does not restructure the script.

### Proposed new functions

| Function | Inserted after | Responsibility |
|---|---|---|
| `install_admin_key()` (optional) | `add_user` | If an admin public key is supplied (`--admin-key`/`AUTHORIZED_KEY`/prompt), validate it with `ssh-keygen -l -f`, then **append it (deduped) to the admin user's `authorized_keys`** with correct perms and **skip the blind copy of root's keys**. Public key only. When no key is supplied, fall back to today's copy-from-root behaviour. |
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

Both patterns **iterate every present `ssh_host_*` pair** (ed25519, rsa, ecdsa) —
backing up only a subset would still trigger "host key changed" warnings for
clients pinned to an omitted type. The implementation will **try A, fall back to
B** if the SSH-key template fields are absent in the installed CLI.

**Item naming & dedupe:** items go in a dedicated **`vps-harden`** folder, named
**`vps-harden/<hostname>`**, and are **updated in place if they already exist**
(matched on `hostname + /etc/machine-id`) so re-running hardening never litters the
vault with duplicates.

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

> **Status:** Phase 1 is implemented. `vps-lockdown.sh` now detects containers
> (`detect_container`/`skip_in_container`) and auto-skips swap, sysctl, the
> `tmpfs` fstab entry, UFW, and ksplice on LXC/Docker; and a per-step backout
> library (`init_backout`, `step_begin`, `change_record`, `record_inverse`,
> `step_revert`, `step_commit`) writes a manifest under
> `/var/backups/vps-harden/<run-id>/` and auto-reverts a failed step (wired into
> swap, server-hardening, and SSH-config changes).
>
> **Phase 2** adds `install_admin_key()` (called after `add_user`): installs a
> supplied admin **public** key (`AUTHORIZED_KEY` env or prompt) — validated via
> `ssh-keygen -l -f` with a prefix-regex fallback, private keys refused — into the
> target user's `authorized_keys` (append + dedupe, perms 600 / `.ssh` 700).
> When a key is supplied, `add_user()` skips its blind copy of root's
> `authorized_keys`; with no key supplied, that copy-from-root fallback is kept.
>
> **Phase 3** adds `bitwarden_backup()` (called after `restart_sshd`): an opt-in,
> non-fatal backup of all `/etc/ssh/ssh_host_*` files to Bitwarden. It detects
> `bw`/`jq` (skips cleanly if absent), resolves a session from `BW_SESSION` or
> `bw unlock --raw` (never logging secrets), then creates a secure-note item
> named `vps-harden/<hostname>` in a `vps-harden` folder and attaches every host
> key — deleting any existing same-named item first so re-runs don't duplicate.
> If anything is missing or fails, hardening still succeeds. **Note:** the
> vault-interaction paths could not be executed in CI (no `bw`); only the
> declined / `bw`-absent skip paths and syntax were validated — they need a
> one-time check on a host with `bw` installed.
>
> **Phase 4** adds the audit gate: `find_vps_audit()` locates the read-only
> `vps-audit.sh`, and `run_audit_gate()` (run after `install_complete`) executes
> it with `--json`, parses `critical_fails` (jq, with a grep fallback), and
> **halts with exit 2 if any critical check FAILed** unless
> `--ignore-audit-failures` is set — non-fatal/skipped when the audit tool is
> absent. A `--audit` flag runs the read-only audit and exits without changes.
> The matching `vps-audit --json`/exit-code companion is vps-audit#3.
>
> **Phase 5 (CLI/non-interactive, in progress)** adds `parse_args()` + `ask_yn()`:
> flags `--admin-key`/`--admin-key-file`, `--ssh-port`, `--user`, `--yes`,
> `--audit`, `--ignore-audit-failures`, `--help`. In `--yes` mode every prompt
> auto-answers a safe default **without blocking** — and, to avoid lockout, it
> only disables password auth when an admin key was supplied and only disables
> root login when a user or key exists. Still pending in Phase 5: the Bitwarden
> **Secrets Manager** profile and the **local key-bootstrap** script. Phase 6
> (distro/LXC profiles + CIS depth) and Phase 7 (docs) remain planned.
>
> ⚠️ `--yes` is validated in isolation (parsing + non-blocking defaults); the full
> unattended run needs a real-VM test before production use.

1. **Phase 1 — Per-step backout foundation (§7.1) + container guard.** A
   `change_record` + per-step `trap`-revert helper so every subsequent mutating
   step is backed up and auto-reverts on failure, **plus an `is_container()` guard
   that auto-skips host-managed steps on LXC** (swap, sysctl, firewall enable,
   `tmpfs` fstab, ksplice). Built first because everything else depends on both for
   safety and for running on LXC as well as VMs.
2. **Phase 2 — `install_admin_key()` (public key only).** Validate and install a
   supplied pubkey. No Bitwarden dependency.
3. **Phase 3 — `bitwarden_backup()` host-key backup**, Pattern A with Pattern B
   fallback, all preconditions detected, fully non-fatal.
4. **Phase 4 — Audit gate (§7.2).** Wire read-only `vps-audit.sh` between
   steps/phases; a failing **critical** check **blocks roll-forward** (exit
   non-zero) unless `--ignore-audit-failures` is passed. Add a `--audit` dry-run
   mode to `vps-lockdown.sh`.
5. **Phase 5 — Non-interactive automation (§7.3).** CLI flags (`--admin-key`,
   `--ssh-port`, `--yes`, `--audit`, `--ignore-audit-failures`) and a Secrets
   Manager profile.
6. **Phase 6 — Cross-distro + LXC + CIS depth (§7.4).** Distro/service
   abstraction in priority order **Debian family → Red Hat family → Alpine**, LXC
   detection, and the deeper konstruktoid-style controls.
7. **Phase 7 — docs.** Update `README.md` for each capability as it lands.

---

## 7. Now in full scope (was previously deferred)

### 7.1 Backout / rollback — per-step (first-class)

**Decision: rollback is per-step, not whole-run.** Each mutating step is
self-contained and reverts itself on failure; the script never tries to "undo the
entire run" as a single operation. Adopt the pratiktri pattern (timestamped
backups + revert functions) at step granularity:

- A `change_record <path>` helper copies any file to
  `<path>.vps-harden.<timestamp>.bak` **before** that step modifies it, and for
  non-file changes (package installs, `ufw enable`, service state) records the
  matching inverse action (e.g. `ufw disable`, `apt remove`).
- **Each step runs under its own `trap`**: if the step fails, **only that step
  auto-reverts** — restoring its `.bak` / running its inverse, then `sshd -t` and
  reload where SSH is involved — and the run stops cleanly with SSH intact. No
  half-applied change is left behind. This is the contract.
- A manifest at `/var/backups/vps-harden/<run-id>/manifest` is still written, but
  **for auditability and manual recovery**, not as an automatic full-run replay.
- This is the safety net that makes the aggressive SSH/firewall/CIS changes in
  §7.4 safe to apply.
- Extends — not replaces — the existing `sshd_config` backup (`vps-lockdown.sh:464`).

### 7.2 Read-only audit — the non-destructive sibling + roll-forward gate

`vps-audit` is the **non-destructive version of the suite**: `vps-audit.sh`
already performs 53 PASS/WARN/FAIL checks and changes nothing. It stays strictly
read-only — the "what would / did change" tool — and becomes the gate that
governs whether `vps-lockdown` is allowed to proceed:

- **Critical check blocks roll-forward.** Between steps/phases, `vps-lockdown`
  runs the read-only audit; **if a _critical_ check fails, the run halts and does
  not roll forward** to the next step, exiting non-zero. It only proceeds past a
  failed critical check when explicitly overridden with `--ignore-audit-failures`
  (alias `--force-forward`). Non-critical findings warn and continue.
- **Which checks are "critical"** (vs warn-only) is defined in `vps-audit` so the
  classification lives with the audit tool, not the hardening script.
- **Dry-run / `--audit` mode in `vps-lockdown.sh`:** a read-only pass that reports
  what *would* change without writing anything — mirrors `vps-audit`'s philosophy
  and lets operators preview before committing.
- **Machine-readable output (cross-repo, `vps-audit`):** add a `--json` + a
  meaningful **exit code** mode to `vps-audit.sh` so `vps-lockdown` (and CI) can
  consume results programmatically to implement the gate above. Small companion
  change on the `vps-audit` repo's matching branch; the tool stays read-only.

### 7.3 Non-interactive automation

- **CLI flags** (pratiktri-style): `--admin-key`, `--ssh-port`, `--user`,
  `--yes`, `--audit`, `--ignore-audit-failures` so the same script serves guided
  *and* unattended runs. Interactive prompts remain the default when flags are
  absent. (No `--rollback` command — rollback is per-step and automatic, §7.1.)
- **Bitwarden Secrets Manager** profile (machine account + scoped access token)
  for fleet automation, selected when a token is present instead of an
  interactive `bw` session (§4.3).
- **Local bootstrap script** (operator's trusted machine): generate the admin
  ed25519 key, store the **private** key in Bitwarden locally, and pass only the
  **public** key to `vps-lockdown.sh` — the safe inverse of pratiktri's on-server
  key generation (§2, §9).

### 7.4 Cross-distro, LXC awareness, and CIS-depth hardening

- **Distro/service abstraction** (pratiktri): detect `apt`/`dnf`/`zypper`/
  `pacman` and systemd/sysvinit so the suite runs beyond Ubuntu. **Priority order:
  Debian family first → Red Hat family next → Alpine last.** Split into profiles
  `debian-ubuntu`, `rhel-fedora`, `alpine`, plus the cross-cutting `lxc-limited`
  and `vm-full`.
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
- **Backout (§7.1, per-step):** force a mid-step failure and confirm the step's
  `trap` auto-reverts **just that step** (file restored from `.bak` / inverse
  action run), the run stops cleanly, SSH stays reachable, and the manifest
  records what happened. Confirm no half-applied change remains.
- **Audit gate (§7.2):** seed a critical regression and confirm `vps-lockdown`
  **halts and exits non-zero** (no roll-forward), then that `--ignore-audit-failures`
  lets it proceed. `--audit` dry-run writes nothing (verify via unchanged file
  mtimes); `vps-audit.sh --json` parses and its exit code reflects critical fails.
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
| 1 | **`vps-harden/vps-lockdown.sh`** (this repo, akcryptoguy) | Interactive, monolithic | Ubuntu only | Friendly guided flow; swap; Google Authenticator 2FA; ksplice; MOTD; backs up `sshd_config`; logs to `/var/log/server_hardening.log` | Ubuntu-only; one long file; copies root's `authorized_keys`; no key validation; no rollback |
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
- **From `vps-lockdown.sh` (keep):** the guided interactive UX, swap setup, optional
  2FA, MOTD, and `sshd_config` backup — these make it approachable for newcomers,
  which is this project's audience.
- **From AMega:** nothing net-new; it is the minimal ancestor of #1.
- **From vps-audit:** treat its 53 checks as **acceptance criteria** — run
  `vps-audit.sh` after hardening to confirm SSH root/password/port and firewall
  land as intended. "Harden, then audit" closes the loop.

### Resulting recommendation (all of this is now in scope)

Keep `vps-lockdown.sh`'s approachable interactive flow as the base, and build out the
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

## 10. Decisions locked & remaining open questions

### Locked by review
- **Bitwarden is optional (hard requirement):** the suite must fully harden a box
  **with no Bitwarden present** — no `bw`/`jq`, no vault, no token. Bitwarden only
  adds host-key backup (and, later, Secrets Manager automation); if it is absent
  or fails, every other step still runs and the run still succeeds. See §0.
- **Naming:** the hardening script is **`vps-lockdown.sh`**; `vps-audit` is its
  read-only, non-destructive sibling. Repo stays `vps-harden`.
- **Rollback (§7.1):** **per-step** auto-revert-on-failure is the contract; no
  whole-run `--rollback` command (manifest kept for audit/manual recovery only).
- **Audit gate (§7.2):** a failing **critical** `vps-audit` check **blocks
  roll-forward** (exit non-zero) unless `--ignore-audit-failures` is passed.
- **Distro priority (§7.4):** **Debian family → Red Hat family → Alpine.**
- **Container support (§7.4, pulled into Phase 1):** a lightweight `is_container()`
  guard (via `systemd-detect-virt --container` / `/run/systemd/container` /
  cgroup) lands in Phase 1 and **auto-skips host-managed steps on LXC** — swap,
  `sysctl`, firewall enable, `tmpfs` fstab, and ksplice — so `vps-lockdown.sh`
  runs safely on both VMs and LXC guests immediately, with full per-distro
  profiles still arriving in Phase 6.
- **`install_admin_key` placement (§3):** when an admin public key is supplied
  (`--admin-key`/`AUTHORIZED_KEY`), **install it to the admin user (append +
  dedupe) and skip the blind copy of root's `authorized_keys`**; validate with
  `ssh-keygen -l -f` first. Fall back to today's copy-from-root only when no key
  is supplied.
- **Host keys to back up (§4):** **all present `ssh_host_*` pairs** (ed25519, rsa,
  ecdsa), private + public — partial backup would still trigger "host key changed"
  for clients pinned to an omitted type.
- **Bitwarden item naming/dedupe (§4):** dedicated folder **`vps-harden`**, item
  name **`vps-harden/<hostname>`**, **update-if-exists** keyed on
  `hostname + /etc/machine-id` so re-runs don't litter the vault.
- **`vps-audit --json` sequencing (§7.2):** a **separate PR on the `vps-audit`
  branch, landed first** — isolated, read-only, and a dependency of the audit gate
  (Phase 4); Phases 1–3 don't need it.

### Still open
1. **Critical-vs-warn classification (§7.2)** — needs one deliberate pass to tag
   all 53 `vps-audit` checks. Proposed starter *critical* set (blocks
   roll-forward): SSH root login ≠ `no`; password auth enabled when key-only was
   chosen; firewall inactive or SSH port not allowed; no sudo-capable admin user;
   fail2ban not running. Everything else stays *warn*. **Confirm the critical set.**
