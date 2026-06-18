#!/bin/bash
# Script to Harden Security on Ubuntu 16.04 LTS (untested on anything else)
# This VPS Server Hardening script is designed to be run on new VPS deployments to simplify a lot of the
# basic hardening that can be done to protect your server. I assimilated several design ideas from AMega's
# VPS hardening script which I found on Github seemingly abandoned. I am very happy to finish it.

function akguy_banner() {
    cat << "EOF"
 ▄████████    ▄█   ▄█▄  ▄████████    ▄████████ ▄██   ▄      ▄███████▄     ███      ▄██████▄     ▄██████▄  ███    █▄  ▄██   ▄
  ███    ███   ███ ▄███▀ ███    ███   ███    ███ ███   ██▄   ███    ███ ▀█████████▄ ███    ███   ███    ███ ███    ███ ███   ██▄
  ███    ███   ███▐██▀   ███    █▀    ███    ███ ███▄▄▄███   ███    ███    ▀███▀▀██ ███    ███   ███    █▀  ███    ███ ███▄▄▄███
  ███    ███  ▄█████▀    ███         ▄███▄▄▄▄██▀ ▀▀▀▀▀▀███   ███    ███     ███   ▀ ███    ███  ▄███        ███    ███ ▀▀▀▀▀▀███
▀███████████ ▀▀█████▄    ███        ▀▀███▀▀▀▀▀   ▄██   ███ ▀█████████▀      ███     ███    ███ ▀▀███ ████▄  ███    ███ ▄██   ███
  ███    ███   ███▐██▄   ███    █▄  ▀███████████ ███   ███   ███            ███     ███    ███   ███    ███ ███    ███ ███   ███
  ███    ███   ███ ▀███▄ ███    ███   ███    ███ ███   ███   ███            ███     ███    ███   ███    ███ ███    ███ ███   ███
  ███    █▀    ███   ▀█▀ ████████▀    ███    ███  ▀█████▀   ▄████▀         ▄████▀    ▀██████▀    ████████▀  ████████▀   ▀█████▀
               ▀                      ███    ███
EOF
}

# ###### SECTIONS ######
# 1. CREATE SWAP / if no swap exists, create 1 GB swap
# 2. UPDATE AND UPGRADE / update operating system & pkgs
# 3. INSTALL FAVORED PACKAGES / useful tools & utilities
# 4. INSTALL CRYPTO PACKAGES / common crypto packages
# 5. USER SETUP / add new sudo user, copy SSH keys
# 6. SSH CONFIG / change SSH port, disable root login
# 7. UFW CONFIG / UFW - add rules, harden, enable firewall
# 8. HARDENING / before rules, secure shared memory, etc
# 9. GOOGLE AUTH / enable 2fa using Google Authenticator
# 10. KSPLICE INSTALL / automatically update without reboot
# 11. MOTD EDIT / replace boring banner with customized one
# 12. RESTART SSHD / apply settings by restarting systemctl
# 13. INSTALL COMPLETE / display new SSH and login info

# Add to log command and display output on screen
# echo " $(date +%m.%d.%Y_%H:%M:%S) : $MESSAGE" | tee -a "$LOGFILE"
# Add to log command and do not display output on screen
# echo " $(date +%m.%d.%Y_%H:%M:%S) : $MESSAGE" >> $LOGFILE 2>&1

# write to log only, no output on screen # echo  -e "---------------------------------------------------- " >> $LOGFILE 2>&1
# write to log only, no output on screen # echo  -e "    ** This entry gets written to the log file directly. **" >> $LOGFILE 2>&1
# write to log only, no output on screen # echo  -e "---------------------------------------------------- \n" >> $LOGFILE 2>&1

function setup_environment() {
    ### define colors ###
    lightred=$'\033[1;31m'  # light red
    red=$'\033[0;31m'  # red
    lightgreen=$'\033[1;32m'  # light green
    green=$'\033[0;32m'  # green
    lightblue=$'\033[1;34m'  # light blue
    blue=$'\033[0;34m'  # blue
    lightpurple=$'\033[1;35m'  # light purple
    purple=$'\033[0;35m'  # purple
    lightcyan=$'\033[1;36m'  # light cyan
    cyan=$'\033[0;36m'  # cyan
    lightgray=$'\033[0;37m'  # light gray
    white=$'\033[1;37m'  # white
    brown=$'\033[0;33m'  # brown
    yellow=$'\033[1;33m'  # yellow
    darkgray=$'\033[1;30m'  # dark gray
    black=$'\033[0;30m'  # black
    nocolor=$'\e[0m' # no color

    echo -e -n "${lightred}"
    echo -e -n "${red}"
    echo -e -n "${lightgreen}"
    echo -e -n "${green}"
    echo -e -n "${lightblue}"
    echo -e -n "${blue}"
    echo -e -n "${lightpurple}"
    echo -e -n "${purple}"
    echo -e -n "${lightcyan}"
    echo -e -n "${cyan}"
    echo -e -n "${lightgray}"
    echo -e -n "${white}"
    echo -e -n "${brown}"
    echo -e -n "${yellow}"
    echo -e -n "${darkgray}"
    echo -e -n "${black}"
    echo -e -n "${nocolor}"
    clear

    # Set Vars
    LOGFILE='/var/log/server_hardening.log'
    SSHDFILE='/etc/ssh/sshd_config'
}

function check_distro() {
    # Classify the distro family (priority: Debian -> Red Hat -> Alpine) and pick
    # the package manager. Debian family is fully supported; others are EXPERIMENTAL.
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        case " ${ID_LIKE:-} ${ID:-} " in
            *debian*|*ubuntu*)        DISTRO_FAMILY="debian" ;;
            *rhel*|*fedora*|*centos*) DISTRO_FAMILY="rhel" ;;
            *alpine*)                 DISTRO_FAMILY="alpine" ;;
            *suse*)                   DISTRO_FAMILY="suse" ;;
            *arch*)                   DISTRO_FAMILY="arch" ;;
            *)                        DISTRO_FAMILY="unknown" ;;
        esac
    else
        echo -e "Cannot read /etc/os-release; unsupported system, exiting.\n"
        exit 1
    fi
    detect_pkg_mgr
    export DISTRO_FAMILY
    case "$DISTRO_FAMILY" in
        debian) : ;;  # fully supported
        rhel|alpine|suse|arch)
            echo -e "\n'$DISTRO_FAMILY' family detected ($PKG_MGR) - EXPERIMENTAL."
            echo -e "Universal steps run; apt/ufw-specific hardening is skipped until"
            echo -e "this distro's profile is implemented.\n" ;;
        *)
            echo -e "\nUnrecognized distro - EXPERIMENTAL; proceeding with universal steps only.\n" ;;
    esac
}

function begin_log() {
    # Create Log File and Begin
    echo -e -n "${lightcyan}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SCRIPT STARTED SUCCESSFULLY " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e "------- AKcryptoGUY's VPS Hardening Script --------- " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    sleep 2
}

############################################
## BACKOUT & CONTAINER DETECTION (Phase 1) ##
############################################
# Foundation that everything else builds on:
#  - Container awareness: host-managed steps (swap, sysctl, firewall, ksplice)
#    are skipped inside LXC/Docker where they are blocked or meaningless, so the
#    script runs safely on both VMs and containers.
#  - Per-step backout: every mutating step records what it touches; if that step
#    fails it reverts ONLY itself, leaving SSH and the rest of the system intact.
#    A manifest is written for auditability and manual recovery.

# Detect once whether we are running inside a container.
function detect_container() {
    IS_CONTAINER="no"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt --container --quiet && IS_CONTAINER="yes"
    fi
    if [ "$IS_CONTAINER" = "no" ]; then
        if [ -f /run/systemd/container ] || [ -f /.dockerenv ]; then
            IS_CONTAINER="yes"
        elif grep -qaE '(lxc|docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
            IS_CONTAINER="yes"
        elif [ -n "${container:-}" ]; then
            IS_CONTAINER="yes"
        fi
    fi
    if [ "$IS_CONTAINER" = "yes" ]; then
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : Container detected (LXC/Docker)" | tee -a "$LOGFILE"
        echo -e " Host-managed steps (swap, sysctl, firewall, ksplice) will be skipped." | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        sleep 1
    fi
}

# Return 0 (and log) when a host-managed step should be skipped in a container.
function skip_in_container() {
    local label="$1"
    if [ "${IS_CONTAINER:-no}" = "yes" ]; then
        echo -e -n "${yellow}"
        echo -e " --> Skipping '$label' inside container (host-managed). " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi
    return 1
}

# Initialise the per-run backout manifest.
function init_backout() {
    BACKUP_ROOT="/var/backups/vps-harden"
    RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
    RUN_DIR="$BACKUP_ROOT/$RUN_ID"
    MANIFEST="$RUN_DIR/manifest"
    mkdir -p "$RUN_DIR"
    chmod 700 "$BACKUP_ROOT" "$RUN_DIR" 2>/dev/null
    : > "$MANIFEST"
    echo "# vps-lockdown backout manifest - run $RUN_ID - $(date)" >> "$MANIFEST"
    echo -e -n "${white}"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : Backout manifest at $MANIFEST" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

# Begin a named, individually-revertable step.
function step_begin() {
    CURRENT_STEP="$1"
    STEP_BACKUPS=()
    STEP_INVERSES=()
    echo "STEP $CURRENT_STEP $(date +%s)" >> "$MANIFEST"
}

# Back up a file before it is modified (records ABSENT if it does not yet exist).
function change_record() {
    local path="$1" stamp safe backup
    stamp="$(date +%Y%m%d-%H%M%S)"
    safe="$(echo "$path" | sed 's#/#_#g')"
    backup="$RUN_DIR/${safe}.${stamp}.bak"
    if [ -e "$path" ]; then
        cp -a "$path" "$backup"
        STEP_BACKUPS+=("$path|$backup")
        echo "FILE $path $backup" >> "$MANIFEST"
    else
        STEP_BACKUPS+=("$path|")   # empty backup => file was absent; revert deletes it
        echo "ABSENT $path" >> "$MANIFEST"
    fi
}

# Record an inverse command to undo a non-file change (e.g. 'ufw disable').
function record_inverse() {
    STEP_INVERSES+=("$*")
    echo "CMD $*" >> "$MANIFEST"
}

# Revert ONLY the current step: undo inverse commands, then restore/delete files.
function step_revert() {
    echo -e -n "${lightred}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : Step '$CURRENT_STEP' failed - reverting this step only" | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    local i entry path backup
    for (( i=${#STEP_INVERSES[@]}-1; i>=0; i-- )); do
        eval "${STEP_INVERSES[$i]}" >> "$LOGFILE" 2>&1 || true
    done
    for (( i=${#STEP_BACKUPS[@]}-1; i>=0; i-- )); do
        entry="${STEP_BACKUPS[$i]}"
        path="${entry%%|*}"
        backup="${entry#*|}"
        if [ -n "$backup" ] && [ -e "$backup" ]; then
            cp -a "$backup" "$path"
        elif [ -z "$backup" ]; then
            rm -f "$path"
        fi
    done
    echo "REVERTED $CURRENT_STEP $(date +%s)" >> "$MANIFEST"
}

# Mark the current step as successfully committed.
function step_commit() {
    echo "COMMIT $CURRENT_STEP $(date +%s)" >> "$MANIFEST"
}

############################################
## CLI ARGS & NON-INTERACTIVE MODE (Ph 5) ##
############################################

function usage() {
    cat <<USAGE
Usage: vps-lockdown.sh [options]

  --admin-key "KEY"        Install this SSH PUBLIC key for the admin user
  --admin-key-file PATH    Read the admin public key from a file
  --ssh-port N             Use SSH port N (else prompt / keep 22)
  --user NAME              Create/!use this non-root sudo user
  --yes, -y                Non-interactive: auto-answer prompts with safe
                           defaults (does NOT disable password auth unless an
                           admin key is supplied; does NOT disable root login
                           unless a user or key is supplied)
  --audit                  Run the read-only vps-audit companion and exit
  --cis                    Apply the optional CIS baseline (auditd, AIDE,
                           password aging, sysctl); non-fatal, opt-in
  --ignore-audit-failures  Do not halt on a failed critical audit check
  -h, --help               Show this help and exit

Environment: AUTHORIZED_KEY, BW_SESSION (vault backup),
  BWS_ACCESS_TOKEN + BWS_PROJECT_ID (Secrets Manager backup).
Distros: Debian/Ubuntu fully supported; RHEL/Alpine/SUSE/Arch experimental.
USAGE
}

# Parse CLI flags. Unattended automation sets values here; interactive runs use
# the prompts. Keeps everything optional so a bare run behaves exactly as before.
function parse_args() {
    ASSUME_YES="no"; IGNORE_AUDIT_FAILURES="no"; AUDIT_ONLY="no"; DO_CIS="no"
    SSH_PORT_OPT=""; USER_OPT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --admin-key)            shift; AUTHORIZED_KEY="$1" ;;
            --admin-key=*)          AUTHORIZED_KEY="${1#*=}" ;;
            --admin-key-file)       shift; AUTHORIZED_KEY="$(cat "$1" 2>/dev/null)" ;;
            --admin-key-file=*)     AUTHORIZED_KEY="$(cat "${1#*=}" 2>/dev/null)" ;;
            --ssh-port)             shift; SSH_PORT_OPT="$1" ;;
            --ssh-port=*)           SSH_PORT_OPT="${1#*=}" ;;
            --user)                 shift; USER_OPT="$1" ;;
            --user=*)               USER_OPT="${1#*=}" ;;
            --yes|-y)               ASSUME_YES="yes" ;;
            --ignore-audit-failures|--force-forward) IGNORE_AUDIT_FAILURES="yes" ;;
            --audit)                AUDIT_ONLY="yes" ;;
            --cis)                  DO_CIS="yes" ;;
            -h|--help)              usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        esac
        shift
    done
    export AUTHORIZED_KEY ASSUME_YES IGNORE_AUDIT_FAILURES AUDIT_ONLY DO_CIS SSH_PORT_OPT USER_OPT
}

# Ask a yes/no question. In --yes (ASSUME_YES) mode, auto-answers with DEFAULT
# instead of blocking on input. Usage: ask_yn VARNAME "prompt ... y/n" DEFAULT
function ask_yn() {
    local __var="$1" __prompt="$2" __def="$3" __ans=""
    if [ "${ASSUME_YES:-no}" = "yes" ]; then
        __ans="$__def"
        echo -e "${cyan} $__prompt -> ${__def} (non-interactive)${nocolor}" | tee -a "$LOGFILE"
    else
        while :; do
            echo -e "\n"
            read -n 1 -s -r -p " $__prompt " __ans
            [[ ${__ans,,} == "y" || ${__ans,,} == "n" ]] && break
        done
    fi
    printf -v "$__var" '%s' "$__ans"
}

############################################
## DISTRO / PACKAGE / SERVICE ABSTRACTION ##
############################################
# Phase 6 foundation: detect the package manager + init system so the suite can
# run beyond Ubuntu (priority Debian -> Red Hat -> Alpine). The Debian family is
# fully supported today; on other families the universal steps (user, SSH config,
# backout, audit, service restart) run and apt/ufw-specific steps are skipped.
# Full per-distro package/firewall/CIS profiles are the next increment.

function detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    elif command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper"
    elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman"
    elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
    else PKG_MGR="unknown"; fi
    export PKG_MGR
}

function pkg_install() {
    case "${PKG_MGR:-unknown}" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        pacman) pacman -S --noconfirm "$@" ;;
        apk)    apk add "$@" ;;
        *) return 1 ;;
    esac
}

function svc_enable() {
    if command -v systemctl >/dev/null 2>&1; then systemctl enable "$1" >/dev/null 2>&1
    elif command -v rc-update >/dev/null 2>&1; then rc-update add "$1" >/dev/null 2>&1
    fi
}

# Restart the first service name that exists (e.g. svc_restart sshd ssh).
function svc_restart() {
    local s
    for s in "$@"; do
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart "$s" >/dev/null 2>&1 && return 0
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service "$s" restart >/dev/null 2>&1 && return 0
        elif command -v service >/dev/null 2>&1; then
            service "$s" restart >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# True only on the fully-supported Debian/Ubuntu family. Used to skip apt/ufw-
# specific steps cleanly on other distros until their profiles are implemented.
function is_debian_family() { [ "${DISTRO_FAMILY:-}" = "debian" ]; }

# Open the SSH port using whatever firewall the distro ships (firewalld -> nftables
# -> iptables). EXPERIMENTAL non-Debian baseline; SSH-only and policy left ACCEPT so
# a remote run can never lock itself out.
function firewall_nondebian() {
    local port="${1:-22}"
    skip_in_container "firewall (host-managed in container)" && return 0
    if command -v firewall-cmd >/dev/null 2>&1; then
        svc_enable firewalld; svc_restart firewalld >/dev/null 2>&1
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e " --> firewalld: opened ${port}/tcp." | tee -a "$LOGFILE"
    elif command -v nft >/dev/null 2>&1; then
        nft list table inet filter >/dev/null 2>&1 || nft add table inet filter
        nft 'add chain inet filter input { type filter hook input priority 0 ; policy accept ; }' 2>/dev/null
        nft add rule inet filter input tcp dport "$port" accept 2>/dev/null
        echo -e " --> nftables: allowed tcp/${port} (policy left ACCEPT to avoid lockout)." | tee -a "$LOGFILE"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        echo -e " --> iptables: allowed tcp/${port} (not persisted - install a persistence pkg)." | tee -a "$LOGFILE"
    else
        echo -e " --> No supported firewall tool found; skipping firewall config." | tee -a "$LOGFILE"
    fi
}

# Optional CIS-leaning baseline (auditd + AIDE + password-aging + a couple of
# sysctl). Cross-distro via pkg_install. Opt-in (--cis or prompt) and fully non-
# fatal so it never blocks a hardening run. EXPERIMENTAL beyond the Debian family.
function cis_baseline() {
    local DOCIS="${DO_CIS:-no}"
    if [ "$DOCIS" != "yes" ]; then
        ask_yn DOCIS "Apply optional CIS baseline (auditd, AIDE, password aging)? y/n" "n"
        [ "${DOCIS,,}" = "y" ] && DOCIS="yes" || DOCIS="no"
    fi
    [ "$DOCIS" = "yes" ] || { echo -e " --> Skipping optional CIS baseline." | tee -a "$LOGFILE"; return 0; }

    echo -e -n "${lightcyan}"; echo -e "\n --> Applying optional CIS baseline (non-fatal)..." | tee -a "$LOGFILE"; echo -e -n "${nocolor}"

    # auditd package name differs by distro (audit on RHEL/SUSE/Arch/Alpine).
    local audit_pkg="auditd"
    case "${DISTRO_FAMILY:-debian}" in rhel|suse|arch|alpine) audit_pkg="audit" ;; esac
    if ! command -v auditctl >/dev/null 2>&1; then
        pkg_install "$audit_pkg" >/dev/null 2>>"$LOGFILE" \
            && echo -e " --> installed $audit_pkg." | tee -a "$LOGFILE" \
            || echo -e " --> could not install $audit_pkg (skip)." | tee -a "$LOGFILE"
    fi
    if ! skip_in_container "auditd enable"; then svc_enable auditd; svc_restart auditd >/dev/null 2>&1; fi

    # AIDE file-integrity baseline (best-effort; init can be slow, so only if absent).
    if ! command -v aide >/dev/null 2>&1; then
        pkg_install aide >/dev/null 2>>"$LOGFILE" \
            && echo -e " --> installed aide." | tee -a "$LOGFILE" \
            || echo -e " --> could not install aide (skip)." | tee -a "$LOGFILE"
    fi

    # Password aging defaults in /etc/login.defs (idempotent).
    if [ -f /etc/login.defs ]; then
        change_record /etc/login.defs
        sed -i -E 's/^#?\s*(PASS_MAX_DAYS)\s+.*/\1   365/' /etc/login.defs 2>/dev/null || true
        sed -i -E 's/^#?\s*(PASS_MIN_DAYS)\s+.*/\1   1/'   /etc/login.defs 2>/dev/null || true
        sed -i -E 's/^#?\s*(PASS_WARN_AGE)\s+.*/\1   7/'   /etc/login.defs 2>/dev/null || true
        echo -e " --> tuned password aging in /etc/login.defs." | tee -a "$LOGFILE"
    fi

    # A couple of universally-safe sysctl items (skipped in containers).
    if ! skip_in_container "CIS sysctl"; then
        local cf=/etc/sysctl.d/99-cis-baseline.conf
        change_record "$cf"
        {
            echo "kernel.randomize_va_space = 2"
            echo "fs.suid_dumpable = 0"
            echo "net.ipv4.conf.all.rp_filter = 1"
        } > "$cf" 2>/dev/null && sysctl --system >/dev/null 2>&1 \
            && echo -e " --> wrote $cf and reloaded sysctl." | tee -a "$LOGFILE" \
            || echo -e " --> could not apply CIS sysctl (skip)." | tee -a "$LOGFILE"
    fi

    echo -e -n "${lightgreen}"; echo -e " --> CIS baseline step complete." | tee -a "$LOGFILE"; echo -e -n "${nocolor}"
}

#########################
## CHECK & CREATE SWAP ##
#########################

function create_swap() {
    # Check for and create swap file if necessary
    # this is an alternative that will disable swap, and create a new one at the size you like
    # sudo swapoff -a && sudo dd if=/dev/zero of=/swapfile bs=1M count=6144 MB && sudo mkswap /swapfile && sudo swapon /swapfile
    echo -e -n "${yellow}"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : CHECK FOR AND CREATE SWAP " | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${white}"

    # Swap is host-managed inside containers (swapon is blocked) - skip there.
    if skip_in_container "swap creation"; then return; fi

    # Check for swap file - if none, create one
    if free | awk '/^Swap:/ {exit !$2}'; then
        echo -e -n "${lightred}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : Swap exists- No changes made " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n"  | tee -a "$LOGFILE"
        sleep 2
        echo -e -n "${nocolor}"
    else
        # set swap to twice the physical RAM but not less than 2GB
        PHYSRAM=$(grep MemTotal /proc/meminfo | awk '{print int($2 / 1024 / 1024 + 0.5)}')
        let "SWAPSIZE=2*$PHYSRAM"
        (($SWAPSIZE >= 1 && $SWAPSIZE >= 31)) && SWAPSIZE=31
        (($SWAPSIZE <= 2)) && SWAPSIZE=2

        step_begin "create_swap"
        change_record /etc/fstab
        if fallocate -l ${SWAPSIZE}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile; then
            record_inverse "swapoff /swapfile 2>/dev/null; rm -f /swapfile"
            cp /etc/fstab /etc/fstab.bak && echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
            step_commit
            echo -e -n "${lightgreen}"
            echo -e "-------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SWAP CREATED SUCCESSFULLY " | tee -a "$LOGFILE"
            echo -e "--> Thanks @Cryptotron for supplying swap code <-- "
            echo -e "-------------------------------------------------- \n" | tee -a "$LOGFILE"
            sleep 2
            echo -e -n "${nocolor}"
        else
            step_revert
            echo -e -n "${lightred}"
            echo -e " $(date +%m.%d.%Y_%H:%M:%S) : Swap creation failed - skipped, no changes kept" | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            sleep 2
        fi
    fi
}

######################
## UPDATE & UPGRADE ##
######################

function update_upgrade() {
    if ! is_debian_family; then echo -e "${yellow} --> Skipping apt update/upgrade on non-Debian distro.${nocolor}" | tee -a "$LOGFILE"; return 0; fi

    # NOTE I learned the hard way that you must put a "\" BEFORE characters "\" and "`"
    echo -e -n "${lightcyan}"
    printf "  ___  ____    _   _           _       _ \n" | tee -a "$LOGFILE"
    printf " / _ \/ ___|  | | | |_ __   __| | __ _| |_ ___ \n" | tee -a "$LOGFILE"
    printf "| | | \\___ \\  | | | | '_ \\ / _\` |/ _\` | __/ _ \\ \n" | tee -a "$LOGFILE"
    printf "| |_| |___) | | |_| | |_) | (_| | (_| | ||  __/ \n" | tee -a "$LOGFILE"
    printf " \___/|____/   \___/| .__/ \__,_|\__,_|\__\___| \n" | tee -a "$LOGFILE"
    printf "                    |_| \n"
    echo -e -n "${yellow}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INITIATING SYSTEM UPDATE " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${white}"
    # remove grub to prevent interactive user prompt: https://tinyurl.com/y9pu7j5s
    echo '# export DEBIAN_FRONTEND=noninteractive' | tee -a "$LOGFILE"
    export DEBIAN_FRONTEND=noninteractive
    echo '# rm /boot/grub/menu.lst     (prevent update issue)' | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    rm /boot/grub/menu.lst
    echo '# update-grub-legacy-ec2 -y  (prevent update issue)' | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    update-grub-legacy-ec2 -y | tee -a "$LOGFILE"
    echo -e -n "${white}"
    echo '# apt-get -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true update' | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    apt-get -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true update | tee -a "$LOGFILE"
    echo -e -n "${white}"
    echo -e "----------------------------------------------------------------------------- " | tee -a "$LOGFILE"
    echo ' # apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install figlet' | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install figlet | tee -a "$LOGFILE"
    echo -e -n "${lightgreen}"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SYSTEM UPDATED SUCCESSFULLY " | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"

    echo -e -n "${cyan}"
    figlet System Upgrade | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INITIATING SYSTEM UPGRADE " | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${white}"
    echo ' # apt-get -o Dpkg::Options::="--force-confold" upgrade -q -y' | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    apt-get -o Dpkg::Options::="--force-confold" upgrade -q -y | tee -a "$LOGFILE"
    echo -e -n "${lightgreen}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SYSTEM UPGRADED SUCCESSFULLY " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

#
#  PROMPT WHETHER USER WANTS TO INSTALL FAVORED PACKAGES OR ALSO ADD THEIR OWN CUSTOM PACKAGES
#

function favored_packages() {
    if ! is_debian_family; then echo -e "${yellow} --> Skipping apt package install on non-Debian distro.${nocolor}" | tee -a "$LOGFILE"; return 0; fi
    # install my favorite and commonly used packages
    echo -e -n "${lightcyan}"
    figlet Install Favored | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INSTALLING FAVORED PACKAGES " | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${white}"
    echo ' # apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install ' | tee -a "$LOGFILE"
    echo '   htop nethogs ufw fail2ban wondershaper glances ntp figlet lsb-release ' | tee -a "$LOGFILE"
    echo '   update-motd unattended-upgrades secure-delete net-tools dnsutils' | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install \
        htop nethogs ufw fail2ban wondershaper glances ntp figlet lsb-release \
        update-motd unattended-upgrades secure-delete net-tools dnsutils | tee -a "$LOGFILE"
    echo -e -n "${lightgreen}"
    echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : FAVORED INSTALLED SUCCESFULLY " | tee -a "$LOGFILE"
    echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

#  PROMPT WHETHER USER WANTS TO INSTALL COMMON CRYPTO PACKAGES OR NOT

#####################
## CRYPTO PACKAGES ##
#####################
function crypto_packages() {
    if ! is_debian_family; then echo -e "${yellow} --> Skipping apt crypto-package install on non-Debian distro.${nocolor}" | tee -a "$LOGFILE"; return 0; fi
    echo -e -n "${lightcyan}"
    figlet Crypto Setup | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : QUERY TO INSTALL CRYPTO PKGS " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- \n"
    echo -e -n "${lightcyan}"
    echo " I frequently use Ubuntu Virtual Machines for cryptocurrency projects"
    echo " to compile or build wallets from source code but I realize that there"
    echo " are plenty of other reasons to use them. If using the VPS for crypto,"
    echo " installing these packages now can save you some time later. "
    echo -e "\n"

        echo -e -n "${cyan}"
            ask_yn INSTALLCRYPTO "Would you like to install these crypto packages now? y/n" "n"
        echo -e "${nocolor}"

    # check if INSTALLCRYPTO is valid
    if [ "${INSTALLCRYPTO,,}" = "Y" ] || [ "${INSTALLCRYPTO,,}" = "y" ]
    then echo -e "\n"
        echo -e -n "${yellow}"
        echo -e " Great; let's install them now... \n"
        echo -e -n "${lightcyan}"
        figlet Install Crypto | tee -a "$LOGFILE"
        echo -e -n "${yellow}"
        echo -e "-------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INSTALLING CRYPTO PACKAGES " | tee -a "$LOGFILE"
        echo -e "-------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo ' # add-apt-repository -yu ppa:bitcoin/bitcoin' | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        add-apt-repository -yu ppa:bitcoin/bitcoin | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo -e "---------------------------------------------------------------------- " | tee -a "$LOGFILE"
        echo ' # apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install ' | tee -a "$LOGFILE"
        echo '   build-essential g++ protobuf-compiler libboost-all-dev autotools-dev ' | tee -a "$LOGFILE"
        echo '   automake libcurl4-openssl-dev libboost-all-dev libssl-dev libdb++-dev ' | tee -a "$LOGFILE"
        echo '   make autoconf automake libtool git apt-utils libprotobuf-dev pkg-config ' | tee -a "$LOGFILE"
        echo '   libcurl3-dev libudev-dev libqrencode-dev bsdmainutils pkg-config libssl-dev ' | tee -a "$LOGFILE"
        echo '   libgmp3-dev libevent-dev jp2a pv virtualenv lsb-release update-motd ' | tee -a "$LOGFILE"
        echo -e "----------------------------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${lightred}"
        echo -e " This step can appear to hang for a minute or two so don't be alarmed "
        echo -e "---------------------------------------------------------------------- "
        echo -e -n "${nocolor}"
        apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install \
            build-essential g++ protobuf-compiler libboost-all-dev autotools-dev \
            automake libcurl4-openssl-dev libboost-all-dev libssl-dev libdb++-dev \
            make autoconf automake libtool git apt-utils libprotobuf-dev pkg-config \
            libcurl3-dev libudev-dev libqrencode-dev bsdmainutils pkg-config libssl-dev \
            libgmp3-dev libevent-dev jp2a pv virtualenv lsb-release update-motd  | tee -a "$LOGFILE"
			
        # need more testing to see if autoremove breaks the script or not
        # apt autoremove -y | tee -a "$LOGFILE"
        clear
        echo -e -n "${lightgreen}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : CRYPTO INSTALLED SUCCESFULLY " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    else 	echo -e -n "${yellow}"
        clear
        echo  -e "----------------------------------------------------- " >> $LOGFILE 2>&1
        echo  "    ** User chose not to install crypto packages **" >> $LOGFILE 2>&1
        echo  -e "-----------------------------------------------------" >> $LOGFILE 2>&1
    fi
    echo -e -n "${lightgreen}"
    echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : CRYPTO PACKAGE SETUP COMPLETE " | tee -a "$LOGFILE"
    echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

################
## USER SETUP ##
################

function add_user() {
    # query user to setup a non-root user account or not
    echo -e -n "${lightcyan}"
    figlet User Setup | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : QUERY TO CREATE NON-ROOT USER " | tee -a "$LOGFILE"
    echo -e "----------------------------------------------------- \n"
    echo -e -n "${lightcyan}"
    echo " Conventional wisdom would encourage you to disable root login over SSH"
    echo " because it makes accessing your server more difficult if you use password"
    echo " authentication. Since using RSA public-private key authentication is"
    echo " infinitely more secure, I will not think less of you if you choose to"
    echo " use an RSA key and continue to login as root. I am able to create a "
    echo -e " non-root user if you want me to, but it is not required. \n"
    
            echo -e -n "${cyan}"
            if [ -n "${USER_OPT:-}" ]; then ADDUSER="y"; else ask_yn ADDUSER "Would you like to add a non-root user? y/n" "n"; fi
        echo -e "${nocolor}"

    # check if ADDUSER is valid
    if [ "${ADDUSER,,}" = "Y" ] || [ "${ADDUSER,,}" = "y" ]
    then echo -e "\n"
        echo -e -n "${yellow}"
        echo -e " Great; let's set one up now... \n"
        echo -e -n "${cyan}"
        if [ -n "${USER_OPT:-}" ]; then UNAME="$USER_OPT"; else
        read -p " Enter New Username: " UNAME
        while [[ "$UNAME" =~ [^0-9A-Za-z]+ ]] || [ -z "$UNAME" ]; do echo -e "\n"
            echo -e -n "${lightred}"
            read -p " --> Please enter a username that contains only letters or numbers: " UNAME
            echo -e -n "${nocolor}"
        done
        fi
        echo -e "\n"
        echo -e -n "${yellow}"
        echo  -e " User elected to create a new user named ${UNAME,,}. \n" >> $LOGFILE 2>&1
        echo -e -n "${cyan}"
        id -u "${UNAME,,}" >> $LOGFILE > /dev/null 2>&1
        if [ $? -eq 0 ]
        then
            clear
            echo -e -n "${yellow}"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SKIPPING : User Already Exists " | tee -a "$LOGFILE"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else
            echo -e -n "${cyan}"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            # Portable user creation + admin group across distro families.
            # Debian/Ubuntu sudo group; RHEL/SUSE/Arch/Alpine use 'wheel'.
            local _u="${UNAME,,}" _grp="sudo"
            case "${DISTRO_FAMILY:-debian}" in rhel|suse|arch|alpine) _grp="wheel" ;; esac
            if is_debian_family && command -v adduser >/dev/null 2>&1; then
                adduser --gecos "" "$_u" | tee -a "$LOGFILE"
            elif command -v useradd >/dev/null 2>&1; then
                useradd -m -s /bin/bash "$_u" 2>&1 | tee -a "$LOGFILE"
                echo -e " --> Set a password for $_u:" ; passwd "$_u"
                # ensure 'sudo' is available and the wheel group is permitted
                command -v sudo >/dev/null 2>&1 || pkg_install sudo >/dev/null 2>&1 || true
                if [ -f /etc/sudoers ] && ! grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL' /etc/sudoers; then
                    sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL)\?\s*ALL\)/\1/' /etc/sudoers 2>/dev/null || true
                fi
            elif command -v adduser >/dev/null 2>&1; then   # busybox (Alpine)
                adduser -D -s /bin/sh "$_u" 2>&1 | tee -a "$LOGFILE"
                echo -e " --> Set a password for $_u:" ; passwd "$_u"
                command -v sudo >/dev/null 2>&1 || pkg_install sudo >/dev/null 2>&1 || true
            fi
            if command -v usermod >/dev/null 2>&1; then
                usermod -aG "$_grp" "$_u" | tee -a "$LOGFILE"
            elif command -v addgroup >/dev/null 2>&1; then   # busybox
                addgroup "$_u" "$_grp" 2>&1 | tee -a "$LOGFILE"
            fi
            echo -e -n "${lightgreen}"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : '${UNAME,,}' added to SUDO group" | tee -a "$LOGFILE"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            # copy SSH keys (FALLBACK only): when an admin public key is supplied
            # via AUTHORIZED_KEY, install_admin_key() places it and we do NOT
            # blindly copy root's authorized_keys (which may hold stale/unknown keys).
            if [ -n "${AUTHORIZED_KEY:-}" ]
            then
                echo " $(date +%m.%d.%Y_%H:%M:%S) : Admin key supplied; skipping copy of root's authorized_keys" | tee -a "$LOGFILE"
            elif [ -e /root/.ssh/authorized_keys ]
            then mkdir /home/"${UNAME,,}"/.ssh
                chmod 700 /home/"${UNAME,,}"/.ssh
                # copy root SSH key to new non-root user
                cp /root/.ssh/authorized_keys /home/"${UNAME,,}"/.ssh
                # fix permissions on RSA key
                chmod 400 /home/"${UNAME,,}"/.ssh/authorized_keys
                chown "${UNAME,,}":"${UNAME,,}" /home/"${UNAME,,}" -R
                echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : SSH keys were copied to ${UNAME,,}'s profile" | tee -a "$LOGFILE"
            else echo -e -n "${yellow}"
                echo " $(date +%m.%d.%Y_%H:%M:%S) : RSA keys not present for root, so none were copied." | tee -a "$LOGFILE"
            fi
            clear
        fi
    else 	echo -e -n "${yellow}"
        clear
        echo  -e "----------------------------------------------------- " >> $LOGFILE 2>&1
        echo  "    ** User chose not to create a new user **" >> $LOGFILE 2>&1
        echo  -e "-----------------------------------------------------" >> $LOGFILE 2>&1
    fi
    echo -e -n "${lightgreen}"
    echo -e "---------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : USER SETUP IS COMPLETE " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

##########################
## INSTALL ADMIN SSH KEY ##
##########################

function install_admin_key() {
    # Phase 2: install a supplied admin PUBLIC key (public key only).
    # Source of the key: AUTHORIZED_KEY env var (set by automation / future
    # --admin-key flag) or an interactive prompt. When a key is supplied we
    # install it (append + dedupe) and rely on add_user() having skipped the
    # blind copy of root's authorized_keys. If none is supplied we do nothing -
    # add_user()'s copy-from-root fallback already ran.
    local key="${AUTHORIZED_KEY:-}"

    # No key from env -> offer an interactive prompt (skipped in non-interactive mode).
    if [ -z "$key" ] && [ "${ASSUME_YES:-no}" != "yes" ]; then
        echo -e -n "${lightcyan}"
        figlet Admin Key | tee -a "$LOGFILE"
        echo -e -n "${cyan}"
        echo -e " You can install an admin SSH PUBLIC key now (recommended)."
        echo -e " Paste one public key line (e.g. 'ssh-ed25519 AAAA... you@host'),"
        echo -e " or just press ENTER to skip and keep existing key handling.\n"
        read -r -p " Admin public key (or ENTER to skip): " key
        echo -e "${nocolor}"
    fi

    # Nothing supplied -> skip cleanly.
    if [ -z "$key" ]; then
        echo -e -n "${yellow}"
        echo -e " --> No admin public key supplied; skipping (existing key handling kept)." | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi

    # Refuse anything that looks like a PRIVATE key - never put one on the server.
    if echo "$key" | grep -qiE 'PRIVATE KEY'; then
        echo -e -n "${lightred}"
        echo -e " --> That looks like a PRIVATE key. Never place a private key on the server. Skipping." | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi

    # Validate it is a real public key. Prefer ssh-keygen; if that tool is
    # unavailable, fall back to a prefix check so a valid key is not rejected.
    local valid="no"
    if command -v ssh-keygen >/dev/null 2>&1; then
        local tmpkey; tmpkey="$(mktemp)"
        printf '%s\n' "$key" > "$tmpkey"
        if ssh-keygen -l -f "$tmpkey" >/dev/null 2>&1; then valid="yes"; fi
        rm -f "$tmpkey"
    elif echo "$key" | grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-)[a-z0-9@.-]*) [A-Za-z0-9+/]+=*( .*)?$'; then
        valid="yes"
    fi
    if [ "$valid" != "yes" ]; then
        echo -e -n "${lightred}"
        echo -e " --> Not a valid SSH public key; skipping admin key install." | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi

    # Target the new non-root user if one was created, else root.
    local target home akfile
    if [ -n "${UNAME:-}" ] && id -u "${UNAME,,}" >/dev/null 2>&1; then
        target="${UNAME,,}"
    else
        target="root"
    fi
    home="$(getent passwd "$target" | cut -d: -f6)"
    [ -z "$home" ] && home="/root"
    akfile="$home/.ssh/authorized_keys"

    step_begin "install_admin_key"
    install -d -m 700 -o "$target" -g "$target" "$home/.ssh"
    change_record "$akfile"
    touch "$akfile"
    # Append only if not already present (dedupe).
    if grep -qxF "$key" "$akfile" 2>/dev/null; then
        echo -e " --> Admin key already present for $target; no change made." | tee -a "$LOGFILE"
    else
        printf '%s\n' "$key" >> "$akfile"
    fi
    chown "$target":"$target" "$akfile"
    chmod 600 "$akfile"
    step_commit

    echo -e -n "${lightgreen}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : admin public key installed for $target" | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

################
## SSH CONFIG ##
################

function collect_sshd() {
    # Prompt for custom SSH port between 11000 and 65535
    echo -e -n "${lightcyan}"
    figlet SSH Config | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    SSHPORTWAS=$(sed -n -e '/Port /p' $SSHDFILE)
    echo -e -n "${yellow}"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : CONFIGURE SSH SETTINGS " | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " --> Your current SSH port number is ${SSHPORTWAS} <-- " | tee -a "$LOGFILE"
    echo -e "------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    echo -e -n "${lightcyan}"
    echo -e " By default, SSH traffic occurs on port 22, so hackers are always"
    echo -e " scanning port 22 for vulnerabilities. If you change your server to"
    echo -e " use a different port, you gain some security through obscurity.\n"
    if [ -n "${SSH_PORT_OPT:-}" ]; then
        SSHPORT="$SSH_PORT_OPT"
    elif [ "${ASSUME_YES:-no}" = "yes" ]; then
        SSHPORT="22"
    else
        while :; do
            echo -e -n "${cyan}"
            read -p " Enter a custom port for SSH between 11000 and 65535 or use 22: " SSHPORT
            [[ $SSHPORT =~ ^[0-9]+$ ]] || { echo -e -n "${lightred}";echo -e " --> Try harder, that's not even a number. \n";echo -e -n "${nocolor}";continue; }
            if (($SSHPORT >= 11000 && $SSHPORT <= 65535)); then break
            elif [ "$SSHPORT" = 22 ]; then break
            else echo -e -n "${lightred}"
                echo -e " --> That number is out of range, try again. \n"
                echo "---------------------------------------------------- " >> $LOGFILE 2>&1
                echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: User entered: $SSHPORT " >> $LOGFILE 2>&1
                echo "---------------------------------------------------- " >> $LOGFILE 2>&1
                echo -e -n "${nocolor}"
            fi
        done
    fi
    # Take a backup of the existing config (also record it in the backout manifest)
    step_begin "ssh_config"
    change_record "$SSHDFILE"
    BTIME=$(date +%F_%R)
    cat $SSHDFILE > $SSHDFILE."$BTIME".bak
    echo -e "\n"
    echo -e -n "${yellow}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e "     SSH config file backed up to :" | tee -a "$LOGFILE"
    echo -e " $SSHDFILE.$BTIME.bak" | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"

    # create jail.local and replace 'ssh' with custom port or 22
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    sed -i "s/port.*= ssh/port     = $SSHPORT/" /etc/fail2ban/jail.local

    sed -i "s/$SSHPORTWAS/Port $SSHPORT/" $SSHDFILE >> $LOGFILE 2>&1
    clear
    # Error Handling
    if [ $? -eq 0 ]
    then
        echo -e -n "${lightgreen}"
        echo -e "---------------------------------------------------- "
        echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : SSH port set to $SSHPORT " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    else
        echo -e -n "${lightred}"
        echo -e "---------------------------------------------------- "
        echo -e " ERROR: SSH Port couldn't be changed. Check log file for details."
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: SSH port couldn't be changed " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi

    # Set SSHPORTIS to the final value of the SSH port
    SSHPORTIS=$(sed -n -e '/^Port /p' $SSHDFILE)
    step_commit
}

function prompt_rootlogin {
    # Prompt use to permit or deny root login
    ROOTLOGINP=$(sed -n -e '/^PermitRootLogin /p' $SSHDFILE)
    echo -e -n "${lightcyan}"
    figlet Root Login | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "-------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : CONFIGURE ROOT LOGIN " | tee -a "$LOGFILE"
    echo -e "-------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    if [ -n "${UNAME,,}" ]
    then
        if [ -z "$ROOTLOGINP" ]
        then ROOTLOGINP=$(sed -n -e '/^# PermitRootLogin /p' $SSHDFILE)
        else :
        fi
        echo -e -n "${lightcyan}"
        echo -e " If you have a non-root user, you can disable root login to prevent"
        echo -e " anyone from logging into your server remotely as root. This can"
        echo -e " improve security. Disable root login if you don't need it.\n"
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " Your root login settings are: " "$ROOTLOGINP"  | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        
            echo -e -n "${cyan}"
            # non-interactive default: only disable root login if a non-root user
            # or an admin key exists, to avoid locking out the only access.
            if [ -n "${USER_OPT:-}" ] || [ -n "${AUTHORIZED_KEY:-}" ]; then _rl_def="y"; else _rl_def="n"; fi
            ask_yn ROOTLOGIN "Would you like to disable root login? y/n" "$_rl_def"
        echo -e "${nocolor}"
        
        # check if ROOTLOGIN is valid
        if [ "${ROOTLOGIN,,}" = "Y" ] || [ "${ROOTLOGIN,,}" = "y" ]
        then :
            # search for root login and change to no
            sed -i "s/.*PermitRootLogin.*/PermitRootLogin no/" $SSHDFILE >> $LOGFILE
            # Error Handling
            if [ $? -eq 0 ]
            then
                echo -e -n "${lightgreen}"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : Root login disabled " | tee -a "$LOGFILE"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo -e -n "${nocolor}"
            else
                echo -e -n "${lightred}"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo -e " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: Couldn't disable root login" | tee -a "$LOGFILE"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo -e -n "${nocolor}"
            fi
        else  	echo -e -n "${yellow}"
            echo -e "------------------------------------------------------------- " | tee -a "$LOGFILE"
            echo "It looks like you want to enable root login; making it so..." | tee -a "$LOGFILE"
            sed -i "s/.*PermitRootLogin.*/PermitRootLogin yes/" $SSHDFILE >> $LOGFILE 2>&1
            echo -e "------------------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        fi
        ROOTLOGINP=$(sed -n -e '/^PermitRootLogin /p' $SSHDFILE)
    else 	echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- "
        echo " Since you chose not to create a non-root user, "
        echo " I did not disable root login for obvious reasons."
        echo -e "---------------------------------------------------- \n"
        echo -e "----------------------------------------------------- " >> $LOGFILE 2>&1
        echo -e " Root login not changed; no non-root user was created " >> $LOGFILE 2>&1
        echo -e "----------------------------------------------------- \n" >> $LOGFILE 2>&1
        echo -e -n "${nocolor}"
    fi
    clear
    echo -e -n "${yellow}"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " Your root login settings are:" "$ROOTLOGINP" | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

function disable_passauth() {
    # query user to disable password authentication or not

    echo -e -n "${lightcyan}"
    figlet Pass Auth | tee -a "$LOGFILE"
    echo -e "${yellow}"
    echo -e "----------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : PASSWORD AUTHENTICATION " | tee -a "$LOGFILE"
    echo -e "----------------------------------------------- \n"
    echo -e "${lightcyan}"
    echo -e " You can log into your server using an RSA public-private key pair or"
    echo -e " a password.  Using RSA keys for login is tremendously more secure"
    echo -e " than just using a password. If you have installed an RSA key-pair"
    echo -e " and use that to login, you should disable password authentication.\n"
    echo -e "${nocolor}"
    PASSWDAUTH=$(sed -n -e '/.*PasswordAuthentication /p' $SSHDFILE)
    if [ -n "/root/.ssh/authorized_keys" ]
    then
        # PASSWDAUTH=$(sed -n -e '/PasswordAuthentication /p' $SSHDFILE)
        #       if [ -z "${PASSWDAUTH}" ]
        #       then PASSWDAUTH=$(sed -n -e '/^# PasswordAuthentication /p' $SSHDFILE)
        #       else :
        #       fi
        # Prompt user to see if they want to disable password login
        echo -e -n "${yellow}"
        # output to screen
        echo -e "     --------------------------------------------------- "
        echo -e "      Your current password authentication settings are   "
        echo -e "             ** $PASSWDAUTH ** " | tee -a "$LOGFILE"
        echo -e "     --------------------------------------------------- \n"
        # output to log
        echo -e "--------------------------------------------------- " >> $LOGFILE 2>&1
        echo -e " Your current password authentication settings are   " >> $LOGFILE 2>&1
        echo -e "      ** $PASSWDAUTH ** " >> $LOGFILE 2>&1
        echo -e "--------------------------------------------------- " >> $LOGFILE 2>&1
        
        echo -e -n "${cyan}"
            # non-interactive default: only require key-only login when an admin
            # key was supplied - otherwise this would lock out password users.
            if [ -n "${AUTHORIZED_KEY:-}" ]; then _pa_def="y"; else _pa_def="n"; fi
            ask_yn PASSLOGIN "Would you like to disable password login & require RSA key login? y/n" "$_pa_def"
        echo -e "${nocolor}\n"
        
        # check if PASSLOGIN is valid
        if [ "${PASSLOGIN,,}" = "Y" ] || [ "${PASSLOGIN,,}" = "y" ]
        then
            sed -i "s/PasswordAuthentication .*/PasswordAuthentication no/" $SSHDFILE >> $LOGFILE
            sed -i "s/#PasswordAuthentication .*/PasswordAuthentication no/" $SSHDFILE >> $LOGFILE
            sed -i "s/# PasswordAuthentication .*/PasswordAuthentication no/" $SSHDFILE >> $LOGFILE

            # Error Handling
            if [ $? -eq 0 ]
            then
                echo -e -n "${lightgreen}"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : PassAuth set to NO " | tee -a "$LOGFILE"
                echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
                echo -e -n "${nocolor}"
            else
                echo -e -n "${lightred}"
                echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
                echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: PasswordAuthentication couldn't be changed to no : " | tee -a "$LOGFILE"
                echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
                echo -e -n "${nocolor}"
            fi
        else
            sed -i "s/PasswordAuthentication .*/PasswordAuthentication yes/" $SSHDFILE >> $LOGFILE
            sed -i "s/#PasswordAuthentication .*/PasswordAuthentication yes/" $SSHDFILE >> $LOGFILE
            sed -i "s/# PasswordAuthentication .*/PasswordAuthentication yes/" $SSHDFILE >> $LOGFILE
        fi
    else
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " With no RSA key; I can't disable PasswordAuthentication." | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
    PASSWDAUTH=$(sed -n -e '/PasswordAuthentication /p' $SSHDFILE)
    echo -e -n "${lightgreen}"
    echo -e "-------------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : PASSWORD AUTHENTICATION COMPLETE " | tee -a "$LOGFILE"
    echo -e "-------------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e "    Your PasswordAuthentication settings are now "  | tee -a "$LOGFILE"
    echo -e "        ** $PASSWDAUTH ** " | tee -a "$LOGFILE"
    echo -e "------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
    clear
    echo -e -n "${lightgreen}"
    echo -e "------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SSH CONFIG COMPLETE " | tee -a "$LOGFILE"
    echo -e "------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

################
## UFW CONFIG ##
################

function ufw_config() {
    if ! is_debian_family; then
        echo -e "${yellow} --> Non-Debian distro: applying portable firewall baseline instead of UFW.${nocolor}" | tee -a "$LOGFILE"
        firewall_nondebian "${SSHPORT:-22}"
        FIREWALLP="n"
        return 0
    fi
    # query user to disable password authentication or not
    echo -e -n "${lightcyan}"
    figlet Firewall Config | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "---------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : FIREWALL CONFIGURATION " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------- \n"
    echo -e -n "${lightcyan}"
    echo -e " Uncomplicated Firewall (UFW) is a program for managing a"
    echo -e " netfilter firewall designed to be easy to use. We recommend"
    echo -e " that you activate this firewall and assign default rules"
    echo -e " to protect your server."
    echo -e
    echo -e " * If you already configured UFW, choose NO to keep your existing rules\n"
    
        echo -e -n "${cyan}"
            ask_yn FIREWALLP "Would you like to enable UFW firewall and assign basic rules? y/n" "y"
        echo -e "${nocolor}\n"
    
    if { [ "${FIREWALLP,,}" = "Y" ] || [ "${FIREWALLP,,}" = "y" ]; } && skip_in_container "firewall (UFW) configuration"; then
        # netfilter is host-managed in containers; ensure restart_sshd won't try to enable UFW
        FIREWALLP="n"
    elif [ "${FIREWALLP,,}" = "Y" ] || [ "${FIREWALLP,,}" = "y" ]
    then	echo -e -n "${nocolor}"
        # make sure ufw is installed #
        apt-get install ufw -qqy >> $LOGFILE 2>&1
        # add firewall rules
        echo -e -n "${white}"
        echo -e "------------------------------------------- " | tee -a "$LOGFILE"
        echo " # ufw default allow outgoing"
        ufw default allow outgoing >> $LOGFILE 2>&1
        echo -e "------------------------------------------- " | tee -a "$LOGFILE"
        echo " # ufw default deny incoming"
        ufw default deny incoming >> $LOGFILE 2>&1
        echo -e "------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " # ufw allow $SSHPORT" | tee -a "$LOGFILE"
        ufw allow "$SSHPORT" | tee -a "$LOGFILE"
        echo -e "------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        sleep 1
        # wait until after SSHD is restarted to enable firewall to not break SSH
    else	echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " ** User chose not to setup firewall at this time **"  | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        sleep 1
    fi

    clear
    echo -e -n "${lightgreen}"
    echo -e "------------------------------------------------ " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : FIREWALL CONFIG COMPLETE " | tee -a "$LOGFILE"
    echo -e "------------------------------------------------ " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

################
## Hardening  ##
################

function server_hardening() {
    # prompt users on whether to harden server or not
    echo -e -n "${lightcyan}"
    figlet Get Hard | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "-------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : QUERY TO HARDEN THE SERVER " | tee -a "$LOGFILE"
    echo -e "-------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo -e " The next steps are to secure your server's shared memory, enable"
    echo -e " DDOS protection, harden the networking layer, and enable automatic"
    echo -e " installation of security updates.\n"

        echo -e -n "${cyan}"
            ask_yn GETHARD "Would you like to perform these steps now? y/n" "y"
        echo -e "${nocolor}\n"    
    
    # check if GETHARD is valid
    if [ "${GETHARD,,}" = "Y" ] || [ "${GETHARD,,}" = "y" ]
    then
        step_begin "server_hardening"

        # secure shared memory
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SECURING SHARED MEMORY " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo -e ' --> Adding line to bottom of file /etc/fstab'  | tee -a "$LOGFILE"
        echo -e ' tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        sleep 2	; #  dramatic pause
        # /run/shm and fstab mounts are host-managed inside containers - skip there
        if skip_in_container "shared memory hardening"; then :
        # only add line if line does not already exist in /etc/fstab
        elif grep -q "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" /etc/fstab; then :
        else
            change_record /etc/fstab
            echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' >> /etc/fstab
        fi

        # enable DDOS protection
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : ENABLING DDOS PROTECTION " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo -e " Replace /etc/ufw/before.rules with hardened rules " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n " | tee -a "$LOGFILE"
        sleep 2	; #  dramatic pause
        # UFW before.rules is Debian/UFW-specific and host-managed in containers.
        if ! is_debian_family; then
            echo -e " --> Skipping UFW before.rules on non-Debian distro." | tee -a "$LOGFILE"
        elif skip_in_container "UFW DDOS before.rules"; then :
        else
            change_record /etc/ufw/before.rules
            cat etc/ufw/before.rules > /etc/ufw/before.rules
        fi

        # harden the networking layer
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : HARDENING NETWORK LAYER " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo -e " --> Secure /etc/sysctl.conf with hardening rules " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n " | tee -a "$LOGFILE"
        sleep 2	; #  dramatic pause
        # kernel sysctl is largely read-only/namespaced inside containers - skip there
        if skip_in_container "sysctl network hardening"; then :
        else
            change_record /etc/sysctl.conf
            cat etc/sysctl.conf > /etc/sysctl.conf
        fi

        # enable automatic security updates
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : ENABLING SECURITY UPDATES " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo -e " Configure system to auto install security updates " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n " | tee -a "$LOGFILE"
        sleep 2	; #  dramatic pause

        # apt unattended-upgrades is Debian-specific.
        if ! is_debian_family; then
            echo -e " --> Skipping apt unattended-upgrades on non-Debian distro." | tee -a "$LOGFILE"
        else
            . /etc/os-release
            if [[ "${VERSION_ID}" = "16.04" ]]
            then
                change_record /etc/apt/apt.conf.d/10periodic
                cat etc/apt/apt.conf.d/10periodic > /etc/apt/apt.conf.d/10periodic
            else
                change_record /etc/apt/apt.conf.d/20auto-upgrades
                cat etc/apt/apt.conf.d/20auto-upgrades > /etc/apt/apt.conf.d/20auto-upgrades
            fi
            change_record /etc/apt/apt.conf.d/50unattended-upgrades
            cat etc/apt/apt.conf.d/50unattended-upgrades > /etc/apt/apt.conf.d/50unattended-upgrades
            # consider editing the above 50-unattended-upgrades to auto-reboot when necessary
        fi
        step_commit

        # Error Handling
        if [ $? -eq 0 ]
        then 	echo -e " \n" ; clear
            echo -e -n "${green}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : Server Hardened" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else	clear
            echo -e -n "${lightred}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: Hardening Failed" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        fi

    else :
        clear
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " *** User elected not to GET HARD at this time *** " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
}

##################
## Google Auth  ##
##################

function google_auth() {
    # prompt users to install Google Authenticator or not
    echo -e -n "${lightcyan}"
    figlet Goog Auth | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : QUERY TO INSTALL GOOGLE 2FA " | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo -e " You can increase the security of your VPS by installing a 2-factor"
    echo -e " authentication solution which will require a time-based, one-time"
    echo -e " token in addition to your username and password. This installation"
    echo -e " requires you to use the Google Authenticator app on your phone.\n"

        echo -e -n "${cyan}"
            ask_yn GOOGLEAUTH "Would you like to install Google 2FA Authentication? y/n" "n"
        echo -e "${nocolor}\n"    
    
    # check if GOOGLEAUTH is valid
    if [ "${GOOGLEAUTH,,}" = "Y" ] || [ "${GOOGLEAUTH,,}" = "y" ]
    then

        # installing google authenticator
        echo -e -n "${yellow}"
        echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INSTALLING GOOGLE AUTHENTICATOR " | tee -a "$LOGFILE"
        echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"

        echo -e -n "${nocolor}"
        apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install libpam-google-authenticator | tee -a "$LOGFILE"
        google-authenticator

        echo -e ' --> Enabling Google Authenticator in /etc/pam.d/sshd'  | tee -a "$LOGFILE"
        sed -i "s/@include common-auth/#@include common-auth/" /etc/pam.d/sshd
        echo 'auth required pam_google_authenticator.so' | sudo tee -a /etc/pam.d/sshd

        echo -e ' --> Enabling Google Authenticator in /etc/ssh/sshd_config'  | tee -a "$LOGFILE"
        sed -i "s/ChallengeResponseAuthentication no/ChallengeResponseAuthentication yes/" /etc/ssh/sshd_config
        sed -i "s/PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
        echo 'AuthenticationMethods publickey,keyboard-interactive' | sudo tee -a /etc/ssh/sshd_config
        
            # copy Google Auth key to new user if it exists
            if [ "${UNAME,,}" ] && [ -e /root/.google_authenticator ]
            then # copy root Google Authenticator file new non-root user
                cp /root/.google_authenticator /home/"${UNAME,,}"/.google_authenticator
                # fix permissions on RSA key
                chmod 400 /home/"${UNAME,,}"/.google_authenticator
                chown "${UNAME,,}":"${UNAME,,}" /home/"${UNAME,,}" -R
                echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : Google Auth file was applied to ${UNAME,,}'s profile" | tee -a "$LOGFILE"
            else echo -e -n "${yellow}"
                echo " $(date +%m.%d.%Y_%H:%M:%S) : Google Auth file not present for root, so none was copied." | tee -a "$LOGFILE"
            fi

        # Error Handling
        if [ $? -eq 0 ]
        then 	echo -e " \n" ; clear
            echo -e -n "${green}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : 2FA Installed" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else	clear
            echo -e -n "${lightred}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: 2FA Failed" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        fi

    else :
        clear
        echo -e -n "${yellow}"
        echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " *** User chose to not install Google Authenticator *** " | tee -a "$LOGFILE"
        echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
}

#####################
## Ksplice Install ##
#####################

function ksplice_install() {

    # Ksplice live-patches the kernel; containers share the host kernel - skip there
    if skip_in_container "Ksplice kernel live-patching"; then return; fi

    # This KSplice install script only works for Ubuntu 16.04 at the moment
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        if [[ "${VERSION_ID}" != "16.04" ]] ; then
            echo -e "This KSplice install script only works for Ubuntu 16.04 at the moment, skipping.\n"
        else 

    # -------> I still need to install an error check after installing Ksplice to make sure \
        #          the install completed before moving on the configuration

    # prompt users on whether to install Oracle ksplice or not
    # install created using https://tinyurl.com/y9klkx2j and https://tinyurl.com/y8fr4duq
    # Official page: https://ksplice.oracle.com/uptrack/guide
    echo -e -n "${lightcyan}"
    figlet Ksplice Uptrack | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "---------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INSTALL ORACLE KSPLICE " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo -e " Normally, kernel updates in Linux require a system reboot. Ksplice"
    echo -e " Uptrack installs these patches in memory for Ubuntu and Fedora"
    echo -e " Linux so reboots are not needed. It is free for non-commercial use."
    echo -e " To minimize server downtime, this is a good thing to install.\n"
    
        echo -e -n "${cyan}"
            ask_yn KSPLICE "Would you like to install Oracle Ksplice Uptrack now? y/n" "n"
        echo -e "${nocolor}\n" 

        if [ "${KSPLICE,,}" = "Y" ] || [ "${KSPLICE,,}" = "y" ]
        then
        # install ksplice uptrack
        echo -e -n "${yellow}"
        echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : INSTALLING KSPLICE PACKAGES " | tee -a "$LOGFILE"
        echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${white}"
        echo ' # apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install ' | tee -a "$LOGFILE"
        echo '   libgtk2-perl consolekit iproute libck-connector0 libcroco3 libglade2-0 ' | tee -a "$LOGFILE"
        echo '   libpam-ck-connector librsvg2-2 librsvg2-common python-cairo python-gtk2 ' | tee -a "$LOGFILE"
        echo '   python-dbus python-gi python-glade2 python-gobject-2 python-pycurl ' | tee -a "$LOGFILE"
        echo '   python-yaml dbus-x11 python-six python3-yaml ' | tee -a "$LOGFILE"
        echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        apt-get -qqy -o=Dpkg::Use-Pty=0 -o=Acquire::ForceIPv4=true install \
            libgtk2-perl consolekit iproute libck-connector0 libcroco3 libglade2-0 \
            libpam-ck-connector librsvg2-2 librsvg2-common python-cairo python-gtk2 \
            python-dbus python-gi python-glade2 python-gobject-2 python-pycurl \
            python-yaml dbus-x11 python-six python3-yaml | tee -a "$LOGFILE"
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " $(date +%m.%d.%Y_%H:%M:%S) : KSPLICE PACKAGES INSTALLED" | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " --> Download & install Ksplice package from Oracle " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        wget -o /var/log/ksplicew1.log https://ksplice.oracle.com/uptrack/dist/xenial/ksplice-uptrack.deb
        dpkg --log "$LOGFILE" -i ksplice-uptrack.deb
        if [ -e /etc/uptrack/uptrack.conf ]
        then
            echo -e -n "${lightgreen}"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e " $(date +%m.%d.%Y_%H:%M:%S) : KSPLICE UPTRACK INSTALLED" | tee -a "$LOGFILE"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${yellow}"
            echo -e " ** Enabling autoinstall & correcting permissions ** " | tee -a "$LOGFILE"
            sed -i "s/autoinstall = no/autoinstall = yes/" /etc/uptrack/uptrack.conf
            chmod 755 /etc/cron.d/uptrack
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e " ** Activate & install Ksplice patches & updates ** " | tee -a "$LOGFILE"
            echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            cat $LOGFILE /var/log/ksplicew1.log > /var/log/join.log
            cat /var/log/join.log > $LOGFILE
            rm /var/log/ksplicew1.log
            rm /var/log/join.log
            uptrack-upgrade -y | tee -a "$LOGFILE"
            echo -e -n "${lightgreen}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e " $(date +%m.%d.%Y_%H:%M:%S) : KSPLICE UPDATES INSTALLED" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- \n" | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            sleep 1	; #  dramatic pause
            clear
            echo -e -n "${lightgreen}"
            echo -e "------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : Ksplice Enabled" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------- \n" | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else  	echo -e -n "${lightred}"
            clear
            echo -e "-------------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : FAIL : Ksplice was not Installed" | tee -a "$LOGFILE"
            echo -e "-------------------------------------------------------- \n" | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        fi
    else :
        clear
        echo -e -n "${yellow}"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e "     ** User elected not to install Ksplice ** " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi

        fi
    else
        # no, thats not ok!
        echo -e "This script only supports Ubuntu, skipping.\n"
    fi
}

###################
## MOTD Install  ##
###################

function motd_install() {
    # prompt users to install custom MOTD or not
    echo -e -n "${lightcyan}"
    figlet Enhance MOTD | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "--------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : PROMPT USER TO INSTALL MOTD " | tee -a "$LOGFILE"
    echo -e "--------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo -e " The normal MOTD banner displayed after a successful SSH login"
    echo -e " is pretty boring so this mod edits it to include more useful"
    echo -e " information along with a login banner prohibiting unauthorized"
    echo -e " access.  All modifications are strictly cosmetic.\n"

        echo -e -n "${cyan}"
            ask_yn MOTDP "Would you like to enhance your MOTD & login banner? y/n" "y"
        echo -e "${nocolor}\n" 

    # check if MOTDP is affirmative
    if [ "${MOTDP,,}" = "Y" ] || [ "${MOTDP,,}" = "y" ]
    then
        sudo apt-get -o Acquire::ForceIPv4=true update -y
        sudo apt-get -o Acquire::ForceIPv4=true install lsb-release update-motd curl -y
        rm -r /etc/update-motd.d/
        mkdir /etc/update-motd.d/
        touch /etc/update-motd.d/00-header ; touch /etc/update-motd.d/10-sysinfo ; touch /etc/update-motd.d/90-footer ; touch /etc/update-motd.d/99-esm
        chmod +x /etc/update-motd.d/*
        cat etc/update-motd.d/00-header > /etc/update-motd.d/00-header
        cat etc/update-motd.d/10-sysinfo > /etc/update-motd.d/10-sysinfo
        cat etc/update-motd.d/90-footer > /etc/update-motd.d/90-footer
        cat etc/update-motd.d/99-esm > /etc/update-motd.d/99-esm
        sed -i 's,#Banner /etc/issue.net,Banner /etc/issue.net,' /etc/ssh/sshd_config
        cat etc/issue.net > /etc/issue.net
        clear
        # Error Handling
        if [ $? -eq 0 ]
        then echo -e -n "${lightgreen}"
            echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : MOTD & Banner updated" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------------- " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else echo -e -n "${lightred}"
            echo -e "----------------------------------------------- " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: MOTD not updated" | tee -a "$LOGFILE"
            echo -e "----------------------------------------------- \n" | tee -a "$LOGFILE"
        fi

    else echo -e "\n"
        clear
        echo -e -n "${yellow}"
        echo -e "----------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " *** User elected not to customize MOTD & banner *** " | tee -a "$LOGFILE"
        echo -e "----------------------------------------------------- \n" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
}

##################
## Restart SSHD ##
##################

function restart_sshd() {
    # prompt users to leave this session open, then create a second connection after restarting SSHD to make sure they can connect
    echo -e -n "${lightcyan}"
    figlet Restart SSH | tee -a "$LOGFILE"
    echo -e -n "${yellow}"
    echo -e "-------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : PROMPT USER TO RESTART SSH " | tee -a "$LOGFILE"
    echo -e "-------------------------------------------------- \n" | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo " Changes to login security will not take effect until SSHD restarts"
    echo " and firewall is enabled. You should keep this existing connection"
    echo " open while restarting SSHD just in case you have a problem or"
    echo " copied down the information incorrectly. This will prevent you"
    echo -e " from getting locked out of your server.\n"

        echo -e -n "${cyan}"
            ask_yn SSHDRESTART "Would you like to restart SSHD and enable UFW now? y/n" "y"
        echo -e "${nocolor}\n" 

    # check if SSHDRESTART is valid
    if [ "${SSHDRESTART,,}" = "Y" ] || [ "${SSHDRESTART,,}" = "y" ]
    then
        # insert a pause or delay to add suspense
        svc_restart sshd ssh
        if [ "$FIREWALLP" = "yes" ] || [ "$FIREWALLP" = "y" ]
        then ufw --force enable | tee -a "$LOGFILE"
            echo -e " \n" | tee -a "$LOGFILE"
        else :
        fi
        # Error Handling
        if [ $? -eq 0 ]
        then 	echo -e -n "${lightgreen}"
            echo -e "------------------------------------------------------ " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : SSHD restart complete" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------------ " | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            if [ "$FIREWALLP" = "yes" ] || [ "$FIREWALLP" = "y" ]
            echo -e -n "${lightgreen}"
            then echo " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : UFW firewall enabled" | tee -a "$LOGFILE"
                echo -e "------------------------------------------------------ " | tee -a "$LOGFILE"
                echo -e -n "${nocolor}"
            else :
            fi
        else
            echo -e -n "${lightred}"
            echo -e "------------------------------------------------------ " | tee -a "$LOGFILE"
            echo " $(date +%m.%d.%Y_%H:%M:%S) : ERROR: SSHD could not restart" | tee -a "$LOGFILE"
            echo -e "------------------------------------------------------ " | tee -a "$LOGFILE"
        fi

    else echo -e "\n"
        printf "$yellow"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e " *** User elected not to restart SSH at this time *** " | tee -a "$LOGFILE"
        echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
}

##############################
## Bitwarden Host-Key Backup ##
##############################

function bitwarden_backup() {
    # Phase 3: OPTIONAL backup of this server's SSH HOST keys to Bitwarden.
    # Entirely opt-in and NON-FATAL: if declined, or bw/jq are missing, or any
    # call fails, hardening still succeeds. Runs after restart_sshd so it can
    # never interfere with restoring SSH access. Bitwarden is never required.
    echo -e -n "${lightcyan}"
    figlet Bitwarden | tee -a "$LOGFILE"
    echo -e -n "${lightcyan}"
    echo -e " OPTIONAL: back up this server's SSH HOST keys (/etc/ssh/ssh_host_*)"
    echo -e " to Bitwarden so a rebuilt server can keep its host identity."
    echo -e -n "${yellow}"
    echo -e " NOTE: host keys are sensitive - anyone who obtains them can impersonate"
    echo -e " this server. Only do this if your Bitwarden vault is trusted.\n"
    echo -e -n "${cyan}"

    local DOBW=""
    # non-interactive default: skip unless a vault session or Secrets Manager
    # token is pre-supplied (BW_SESSION / BWS_ACCESS_TOKEN).
    local _bw_def="n"; { [ -n "${BW_SESSION:-}" ] || [ -n "${BWS_ACCESS_TOKEN:-}" ]; } && _bw_def="y"
    ask_yn DOBW "Back up SSH host keys to Bitwarden now? y/n" "$_bw_def"
    echo -e "${nocolor}\n"
    if [ "${DOBW,,}" != "y" ]; then
        echo -e -n "${yellow}"
        echo -e " --> User declined Bitwarden host-key backup; skipping." | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi

    # --- Bitwarden Secrets Manager profile (unattended automation) ---
    # If a machine-account token is present and the bws CLI is available, store
    # each host key as a base64 secret instead of using an interactive vault.
    if [ -n "${BWS_ACCESS_TOKEN:-}" ] && command -v bws >/dev/null 2>&1; then
        if [ -z "${BWS_PROJECT_ID:-}" ]; then
            echo -e " --> BWS_ACCESS_TOKEN set but BWS_PROJECT_ID missing; falling back to bw vault." | tee -a "$LOGFILE"
        else
            set +x
            local sf sbase scount=0
            for sf in /etc/ssh/ssh_host_*; do
                [ -e "$sf" ] || continue
                sbase="vps-harden/$(hostname)/$(basename "$sf")"
                if bws secret create "$sbase" "$(base64 -w0 "$sf")" "$BWS_PROJECT_ID" >/dev/null 2>>"$LOGFILE"; then
                    scount=$((scount+1))
                else
                    echo -e " --> bws secret create failed for $sf" | tee -a "$LOGFILE"
                fi
            done
            echo -e -n "${lightgreen}"
            echo -e " --> Stored $scount host-key secret(s) via Bitwarden Secrets Manager." | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            return 0
        fi
    fi

    # Soft dependencies - detect, never auto-install.
    if ! command -v bw >/dev/null 2>&1; then
        echo -e " --> Bitwarden CLI (bw) not found; skipping host-key backup." | tee -a "$LOGFILE"
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e " --> jq not found; skipping host-key backup." | tee -a "$LOGFILE"
        return 0
    fi

    # Resolve a session without writing secrets to the log. Prefer BW_SESSION;
    # otherwise unlock interactively (master password prompt goes to the tty).
    set +x
    local sess="${BW_SESSION:-}"
    if [ -z "$sess" ]; then
        echo -e " Unlocking Bitwarden vault..."
        sess="$(bw unlock --raw 2>>"$LOGFILE")" || true
    fi
    if [ -z "$sess" ]; then
        echo -e " --> No Bitwarden session available; skipping host-key backup." | tee -a "$LOGFILE"
        return 0
    fi

    if ! bw sync --session "$sess" >/dev/null 2>>"$LOGFILE"; then
        echo -e " --> bw sync failed; skipping host-key backup." | tee -a "$LOGFILE"
        unset sess
        return 0
    fi

    local host mid itemname folderid notes
    host="$(hostname)"
    mid="$(cat /etc/machine-id 2>/dev/null || echo unknown)"
    itemname="vps-harden/$host"

    # Find or create the 'vps-harden' folder.
    folderid="$(bw list folders --session "$sess" 2>>"$LOGFILE" | jq -r '.[] | select(.name=="vps-harden") | .id' | head -n1)"
    if [ -z "$folderid" ] || [ "$folderid" = "null" ]; then
        folderid="$(bw get template folder | jq '.name="vps-harden"' | bw encode | bw create folder --session "$sess" 2>>"$LOGFILE" | jq -r '.id')"
    fi

    # Update-if-exists: delete any existing items with this exact name so a re-run
    # never litters the vault with duplicates or stale attachments.
    local id
    for id in $(bw list items --search "$itemname" --session "$sess" 2>>"$LOGFILE" | jq -r --arg n "$itemname" '.[] | select(.name==$n) | .id'); do
        bw delete item "$id" --session "$sess" >/dev/null 2>>"$LOGFILE" || true
    done

    # Create a secure-note item and attach every present host-key file.
    notes="SSH host key backup for ${host} (machine-id ${mid}). Created by vps-lockdown on $(date)."
    local itemid
    itemid="$(bw get template item \
        | jq --arg n "$itemname" --arg notes "$notes" --arg f "$folderid" \
            '.type=2 | .secureNote.type=0 | .name=$n | .notes=$notes | (if $f=="" or $f=="null" then . else .folderId=$f end)' \
        | bw encode | bw create item --session "$sess" 2>>"$LOGFILE" | jq -r '.id')"
    if [ -z "$itemid" ] || [ "$itemid" = "null" ]; then
        echo -e " --> Could not create Bitwarden item; skipping host-key backup." | tee -a "$LOGFILE"
        unset sess
        return 0
    fi

    local f count=0
    for f in /etc/ssh/ssh_host_*; do
        [ -e "$f" ] || continue
        if bw create attachment --file "$f" --itemid "$itemid" --session "$sess" >/dev/null 2>>"$LOGFILE"; then
            count=$((count+1))
        else
            echo -e " --> Failed to attach $f" | tee -a "$LOGFILE"
        fi
    done
    bw sync --session "$sess" >/dev/null 2>>"$LOGFILE" || true
    unset sess BW_SESSION

    echo -e -n "${lightgreen}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : SUCCESS : backed up $count host-key file(s) to Bitwarden item '$itemname'" | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

##############################
## Audit Gate (vps-audit)   ##
##############################

# Locate the read-only vps-audit.sh companion, if present.
function find_vps_audit() {
    local c
    for c in \
        "$(dirname "$0")/vps-audit.sh" \
        "$(dirname "$0")/../vps-audit/vps-audit.sh" \
        "./vps-audit.sh" \
        "../vps-audit/vps-audit.sh" \
        "/opt/vps-audit/vps-audit.sh"; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done
    command -v vps-audit.sh >/dev/null 2>&1 && { command -v vps-audit.sh; return 0; }
    return 1
}

# 'Harden, then audit' gate: run vps-audit.sh --json and block roll-forward if any
# CRITICAL check FAILs, unless --ignore-audit-failures was given. Read-only and
# non-fatal when the audit tool is absent (it's a gate, not a hard dependency).
function run_audit_gate() {
    local label="${1:-post-hardening}"
    local audit json crit
    audit="$(find_vps_audit)" || true

    echo -e -n "${lightcyan}"
    figlet Audit Gate | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"

    if [ -z "$audit" ]; then
        echo -e -n "${yellow}"
        echo -e " --> vps-audit.sh not found; skipping audit gate ($label)." | tee -a "$LOGFILE"
        echo -e " (Place vps-audit.sh alongside this script or in ../vps-audit/ to enable it.)" | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
        return 0
    fi

    echo -e " Running read-only audit: $audit --json" | tee -a "$LOGFILE"
    json="$(bash "$audit" --json 2>>"$LOGFILE")" || true

    # Parse critical_fails with jq, fall back to grep if jq is unavailable.
    if command -v jq >/dev/null 2>&1; then
        crit="$(printf '%s' "$json" | jq -r '.critical_fails' 2>/dev/null)"
    fi
    if [ -z "$crit" ] || [ "$crit" = "null" ]; then
        crit="$(printf '%s' "$json" | grep -o '"critical_fails":[0-9]*' | grep -o '[0-9]*' | head -n1)"
    fi
    [ -z "$crit" ] && crit=0

    if [ "$crit" -gt 0 ] 2>/dev/null; then
        echo -e -n "${lightred}"
        echo -e " --> Audit gate ($label): $crit critical check(s) FAILED:" | tee -a "$LOGFILE"
        if command -v jq >/dev/null 2>&1; then
            printf '%s' "$json" | jq -r '.results[]? | select(.critical and .status=="FAIL") | "     - " + .name + ": " + .message' 2>/dev/null | tee -a "$LOGFILE"
        fi
        echo -e -n "${nocolor}"
        if [ "${IGNORE_AUDIT_FAILURES:-no}" = "yes" ]; then
            echo -e -n "${yellow}"
            echo -e " --> Continuing anyway (--ignore-audit-failures set)." | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
        else
            echo -e -n "${lightred}"
            echo -e " --> Halting. Re-run with --ignore-audit-failures to override." | tee -a "$LOGFILE"
            echo -e -n "${nocolor}"
            exit 2
        fi
    else
        echo -e -n "${lightgreen}"
        echo -e " --> Audit gate ($label): no critical failures." | tee -a "$LOGFILE"
        echo -e -n "${nocolor}"
    fi
}

######################
## Install Complete ##
######################

function install_complete() {
    # Display important login variables before exiting script
    clear
    echo -e -n "${lightcyan}"
    figlet Install Complete -f small | tee -a "$LOGFILE"
    echo -e -n "${lightgreen}"
    echo -e "---------------------------------------------------- " >> $LOGFILE 2>&1
    echo -e " $(date +%m.%d.%Y_%H:%M:%S) : YOUR SERVER IS NOW SECURE " >> $LOGFILE 2>&1
    echo -e -n "${lightpurple}"
    echo -e "---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e "  * * * Save these important login variables! * * *  " | tee -a "$LOGFILE"
    echo -e "---------------------------------------------------- ${yellow}" | tee -a "$LOGFILE"
    echo -e " --> Your SSH port for remote access is" "$SSHPORTIS"	| tee -a "$LOGFILE"
    echo -e " --> Root login settings are:" "$ROOTLOGINP" | tee -a "$LOGFILE"

    if [ "${INSTALLCRYPTO,,}" = "yes" ] || [ "${INSTALLCRYPTO,,}" = "y" ]
    then echo -e " --> Common crypto packages were installed" | tee -a "$LOGFILE"
    fi
    if [ -n "${UNAME,,}" ]
    then echo -e "${white} We created a non-root user named (lower case):${nocolor}" "${UNAME,,}" | tee -a "$LOGFILE"
    else echo -e "${white} A new user was not created during the setup process ${nocolor}" | tee -a "$LOGFILE"
    fi
    echo " ${white}PasswordAuthentication settings:${lightred}" "$PASSWDAUTH" | tee -a "$LOGFILE"
    if [ "${FIREWALLP,,}" = "yes" ] || [ "${FIREWALLP,,}" = "y" ]
    then echo -e "${lightcyan} --> UFW was installed and basic firewall rules were added" | tee -a "$LOGFILE"
    else echo -e "${lightcyan} --> UFW was not installed or configured" | tee -a "$LOGFILE"
    fi
    # if [ "${GETHARD,,}" = "yes" ] || [ "${GETHARD,,}" = "y" ]
    # then echo -e " --> The server and networking layer were hardened <--" | tee -a "$LOGFILE"
    # else echo -e " --> The server and networking layer were NOT hardened" | tee -a "$LOGFILE"
    # fi
    if [ "${KSPLICE,,}" = "yes" ] || [ "${KSPLICE,,}" = "y" ]
    then echo -e " You installed Oracle's Ksplice to update without reboot" | tee -a "$LOGFILE"
    else echo -e " You chose NOT to auto-update OS with Oracle's Ksplice" | tee -a "$LOGFILE"
    fi
    echo -e "${yellow}-------------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " Installation log saved to" $LOGFILE | tee -a "$LOGFILE"
    echo -e " Before modification, your SSH config was backed up to" | tee -a "$LOGFILE"
    echo -e " --> $SSHDFILE.$BTIME.bak"				| tee -a "$LOGFILE"
    echo -e "${lightred} ---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e " | NOTE: Please create a new connection to test SSH | " | tee -a "$LOGFILE"
    echo -e " |       settings before you close this session     | " | tee -a "$LOGFILE"
    echo -e " ---------------------------------------------------- " | tee -a "$LOGFILE"
    echo -e -n "${nocolor}"
}

function display_banner() {

    echo -e "${lightcyan}"
    cat << "EOF"
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
     _    _  __                     _         ____ _   ___   __
    / \  | |/ /___ _ __ _   _ _ __ | |_ ___  / ___| | | \ \ / /
   / _ \ | ' // __| '__| | | | '_ \| __/ _ \| |  _| | | |\ V /
  / ___ \| . \ (__| |  | |_| | |_) | || (_) | |_| | |_| | | |
 /_/   \_\_|\_\___|_|   \__, | .__/ \__\___/ \____|\___/  |_|
                        |___/|_|
            __  __             __  __  ___          __
  -->  \  /|__)/__`   |__| /\ |__)|  \|__ |\ |||\ |/ _`  <--
        \/ |   .__/   |  |/~~\|  \|__/|___| \||| \|\__>
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *
EOF
    echo -e -n "${nocolor}"
}

# ---- parse CLI flags (non-interactive automation) ----
parse_args "$@"

# --audit: read-only mode - just run the audit companion and exit, no changes.
if [ "$AUDIT_ONLY" = "yes" ]; then
    _audit="$(find_vps_audit)" || true
    if [ -n "$_audit" ]; then bash "$_audit"; exit $?; fi
    echo "vps-audit.sh not found; cannot run --audit." >&2
    exit 1
fi

check_distro
setup_environment
display_banner
begin_log
init_backout
detect_container
create_swap
update_upgrade
favored_packages
crypto_packages
add_user
install_admin_key
collect_sshd
prompt_rootlogin
disable_passauth
ufw_config
server_hardening
cis_baseline
google_auth
ksplice_install
motd_install
restart_sshd
bitwarden_backup
install_complete
run_audit_gate "post-hardening"

exit
