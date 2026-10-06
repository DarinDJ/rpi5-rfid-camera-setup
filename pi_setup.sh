#!/bin/bash
# Raspberry Pi 5 node setup for RFID + camera data collection.
# See README.md (Part B). Run on the Pi with sudo, e.g.:
#
#   sudo bash pi_setup.sh --hostname site1-node01 --ip 192.168.137.140
#
# Safe to re-run. The static IP is applied last; the SSH session drops if the IP changes.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash pi_setup.sh --hostname NAME [options]

Required:
  --hostname NAME        Hostname for this Pi (lowercase letters, digits, hyphens)

Network (static IP is only configured when --ip is given):
  --ip ADDR              Static IPv4 address for eth0, e.g. 192.168.137.140
  --prefix N             Subnet prefix length                  (default: 24)
  --gateway ADDR         Gateway                                (default: 192.168.137.1)
  --dns "A B"            DNS servers                            (default: "<gateway> 8.8.8.8")
  --iface NAME           Ethernet interface                     (default: eth0)

Time:
  --ntp ADDR             NTP server the Pi syncs from           (default: the gateway)
  --tz ZONE              Time zone                              (default: UTC)

Other:
  --user NAME            Account used for data collection       (default: the user who ran sudo)
  --no-packages          Skip package installation
  --no-watchdog          Don't enable the hardware watchdog
  --no-sysctl            Don't install the camera network buffer settings
  --nopasswd-sudo        Allow a short list of commands without a sudo password
                         (only if your control software needs it; see README A10)
  -h, --help             Show this help
EOF
}

HOST=""; IP=""; PREFIX=24; GW=192.168.137.1; DNS=""; IFACE=eth0
NTP=""; TZONE=UTC; RUN_USER="${SUDO_USER:-}"
DO_PKGS=1; DO_WATCHDOG=1; DO_SYSCTL=1; DO_NOPASSWD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) HOST="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --gateway) GW="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --ntp) NTP="$2"; shift 2 ;;
    --tz) TZONE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    --no-packages) DO_PKGS=0; shift ;;
    --no-watchdog) DO_WATCHDOG=0; shift ;;
    --no-sysctl) DO_SYSCTL=0; shift ;;
    --nopasswd-sudo) DO_NOPASSWD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1"; usage; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -n "$HOST" ] || { usage; exit 1; }
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "invalid hostname: $HOST"; exit 1; }
[ -n "$RUN_USER" ] && id "$RUN_USER" >/dev/null 2>&1 || { echo "unknown user (use --user)"; exit 1; }
DNS="${DNS:-$GW 8.8.8.8}"
NTP="${NTP:-$GW}"

step() { echo; echo "=== $*"; }

step "Hostname -> $HOST"
hostnamectl set-hostname "$HOST"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOST/" /etc/hosts
grep -q "^127\.0\.1\.1" /etc/hosts || echo -e "127.0.1.1\t$HOST" >> /etc/hosts

step "Time: $TZONE, NTP server $NTP (systemd-timesyncd)"
timedatectl set-timezone "$TZONE"
mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=%s\nFallbackNTP=\n' "$NTP" > /etc/systemd/timesyncd.conf.d/local-ntp.conf
timedatectl set-ntp true
systemctl restart systemd-timesyncd

if [ "$DO_PKGS" -eq 1 ]; then
  step "Packages (RFID serial, GPIO, camera, audio, tools)"
  PKGS="python3-serial python3-rpi-lgpio python3-numpy rpicam-apps ffmpeg socat alsa-utils vim tmux"
  MISSING=$(for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done)
  if [ -n "$MISSING" ]; then
    apt-get -o Acquire::ForceIPv4=true update -q
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y -q $MISSING
  else
    echo "all installed"
  fi
fi

step "Groups for $RUN_USER"
usermod -aG dialout,gpio,i2c,spi,video,audio "$RUN_USER"

if [ "$DO_NOPASSWD" -eq 1 ]; then
  step "Passwordless sudo for date/timedatectl/sysctl/systemctl"
  cat > /etc/sudoers.d/020_datacollect <<EOF
# Commands the control software runs with 'sudo -n' (see README A10)
$RUN_USER ALL=(root) NOPASSWD: /usr/bin/date, /usr/bin/timedatectl, /usr/sbin/sysctl, /usr/bin/systemctl
EOF
  chmod 440 /etc/sudoers.d/020_datacollect
  visudo -cf /etc/sudoers.d/020_datacollect
fi

if [ "$DO_SYSCTL" -eq 1 ]; then
  step "Network buffers for camera streaming (persistent)"
  cat > /etc/sysctl.d/90-camera-stream.conf <<'EOF'
net.core.rmem_max=134217728
net.core.rmem_default=16777216
net.core.wmem_max=134217728
net.core.wmem_default=16777216
net.ipv4.udp_rmem_min=262144
net.ipv4.udp_wmem_min=262144
EOF
  sysctl -q -p /etc/sysctl.d/90-camera-stream.conf
fi

if [ "$DO_WATCHDOG" -eq 1 ]; then
  step "Hardware watchdog (reboot if the Pi freezes)"
  mkdir -p /etc/systemd/system.conf.d
  printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=2min\n' > /etc/systemd/system.conf.d/watchdog.conf
  systemctl daemon-reexec
fi

if [ -n "$IP" ]; then
  step "Static IP $IP/$PREFIX on $IFACE (gateway $GW, DNS $DNS)"
  # Stop other profiles on this interface (e.g. "Wired connection 1") from competing
  nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-3-ethernet"{print $1}' | while IFS= read -r c; do
    [ "$c" = "static-$IFACE" ] || nmcli con mod "$c" connection.autoconnect no || true
  done
  if nmcli -t -f NAME con show | grep -qx "static-$IFACE"; then
    nmcli con mod "static-$IFACE" ipv4.method manual ipv4.addresses "$IP/$PREFIX" \
      ipv4.gateway "$GW" ipv4.dns "$DNS" connection.autoconnect yes
  else
    nmcli con add type ethernet ifname "$IFACE" con-name "static-$IFACE" ipv4.method manual \
      ipv4.addresses "$IP/$PREFIX" ipv4.gateway "$GW" ipv4.dns "$DNS" autoconnect yes >/dev/null
  fi
  echo "done: $HOST at $IP (applying network now; reconnect with: ssh $RUN_USER@$IP)"
  nohup nmcli con up "static-$IFACE" >/dev/null 2>&1 &
else
  echo; echo "done: $HOST (no static IP configured)"
fi
echo "Next: sudo apt full-upgrade -y && sudo rpi-eeprom-update -a && sudo reboot"
