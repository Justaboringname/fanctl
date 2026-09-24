#!/bin/sh
# Installs fanctl as a root LaunchDaemon (fanctld) plus the StatMenu menu bar app.
#   sudo ./install.sh              install / upgrade
#   sudo ./install.sh uninstall    fans back to auto; removes both daemons, the binaries, the app,
#                                  its settings, the control file and the log
set -eu

LABEL=com.justaboringname.fanctld
PLIST=/Library/LaunchDaemons/$LABEL.plist
# The daemon's binary lives where only root can write (fanctld.plist points here); the copy in
# /usr/local/bin is just the command-line tool.
HELPER=/Library/PrivilegedHelperTools/$LABEL
# Root powermetrics that keeps the CPU/DRAM energy counters updating (see fanctld-power.plist).
POWER_LABEL=com.justaboringname.fanctld.power
POWER_PLIST=/Library/LaunchDaemons/$POWER_LABEL.plist

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
USER_NAME=${SUDO_USER:?run via sudo from your own account}
# dscacheutil prints "dir: <path>" on one line even when the path contains spaces.
USER_HOME=$(dscacheutil -q user -a name "$USER_NAME" | sed -n 's/^dir: //p')
[ -d "$USER_HOME" ] || { echo "cannot find home directory for $USER_NAME" >&2; exit 1; }
CTL_DIR="$USER_HOME/Library/Application Support/fanctl"
cd "$(dirname "$0")"

# (Re)loads a system LaunchDaemon. bootout returns as soon as it has signalled the job, but fanctld
# only exits on its next 1 s tick (after handing the fans back to auto); bootstrapping in that
# window fails with "Bootstrap failed: 5: Input/output error" (launchd: 37, operation in progress).
reload() {  # <label> <plist>
    launchctl bootout "system/$1" 2>/dev/null || true
    i=0
    while launchctl print "system/$1" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
    i=0
    until launchctl bootstrap system "$2"; do
        i=$((i + 1))
        [ $i -lt 5 ] || { echo "could not start $1" >&2; exit 1; }
        sleep 1
    done
}

if [ "${1:-}" = uninstall ]; then
    pkill -u "$USER_NAME" -x StatMenu 2>/dev/null || true
    launchctl bootout "system/$LABEL" 2>/dev/null || true  # daemon returns fans to auto on SIGTERM
    launchctl bootout "system/$POWER_LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$POWER_PLIST" "$HELPER" /usr/local/bin/fanctl /var/log/fanctld.log /var/run/fanctl.status
    sudo -u "$USER_NAME" rm -rf /Applications/StatMenu.app /Applications/FanMenu.app "$CTL_DIR"
    sudo -u "$USER_NAME" defaults delete com.justaboringname.statmenu 2>/dev/null || true
    echo "uninstalled (if you enabled 登录时启动, also check System Settings → General → Login Items)"
    exit 0
fi

# Build as the user so the checkout stays user-owned.
sudo -u "$USER_NAME" make fanctl app

# The daemon runs as root, so its binary and every directory above it must be root-only.
# /usr/local/bin is not good enough: Homebrew on Intel (and migrated Macs) makes it user-owned.
[ -d /Library/PrivilegedHelperTools ] || install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
[ "$(stat -f %Su /Library/PrivilegedHelperTools)" = root ] || { echo "/Library/PrivilegedHelperTools is not owned by root" >&2; exit 1; }
install -o root -g wheel -m 755 fanctl "$HELPER"
# The command-line copy. Never change an existing /usr/local/bin's owner (Homebrew may own it).
[ -d /usr/local/bin ] || install -d -o root -g wheel -m 755 /usr/local/bin
install -o root -g wheel -m 755 fanctl /usr/local/bin/fanctl

sudo -u "$USER_NAME" mkdir -p "$CTL_DIR"
[ -f "$CTL_DIR/control" ] || echo auto | sudo -u "$USER_NAME" tee "$CTL_DIR/control" >/dev/null

sed "s|__CONTROL__|$CTL_DIR/control|" fanctld.plist >"$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
reload "$LABEL" "$PLIST"

install -o root -g wheel -m 644 fanctld-power.plist "$POWER_PLIST"
reload "$POWER_LABEL" "$POWER_PLIST"

# The app needs no privileges, so copy it as the user (root writing into the admin-writable
# /Applications would follow anything swapped in between rm and ditto). FanMenu is the old app.
# Quit any running copy (e.g. one started from build/) so there is exactly one set of menu items.
pkill -u "$USER_NAME" -x StatMenu 2>/dev/null || true
pkill -u "$USER_NAME" -x FanMenu 2>/dev/null || true
sudo -u "$USER_NAME" rm -rf /Applications/FanMenu.app /Applications/StatMenu.app
sudo -u "$USER_NAME" ditto build/StatMenu.app /Applications/StatMenu.app
launchctl asuser "$(id -u "$USER_NAME")" sudo -u "$USER_NAME" open /Applications/StatMenu.app || true

echo "fanctld + power sampler running; StatMenu started from /Applications (enable 登录时启动 there)"
