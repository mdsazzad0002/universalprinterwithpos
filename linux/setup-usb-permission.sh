#!/usr/bin/env bash
# Lets the logged-in desktop user print to USB printers (/dev/usb/lp*)
# without joining the "lp" group or logging out. Run once with sudo.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

rule=/etc/udev/rules.d/60-universal-print.rules
cat > "$rule" <<'RULE'
# Universal Print: USB printers (usblp) usable by the active desktop user.
SUBSYSTEM=="usbmisc", KERNEL=="lp[0-9]*", TAG+="uaccess"
RULE

udevadm control --reload-rules
udevadm trigger --subsystem-match=usbmisc --action=change
echo "Installed $rule"
ls -l /dev/usb/ 2>/dev/null || echo "No USB printer connected right now."
command -v getfacl >/dev/null && for d in /dev/usb/lp*; do [[ -e $d ]] && getfacl -p "$d" | grep '^user:'; done || true
