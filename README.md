# Raspberry Pi 5 Setup for RFID + Camera Data Collection

A step-by-step guide to setting up one or more **Raspberry Pi 5** boards as data-collection
nodes. Each node has **USB RFID readers** and a **camera**, and can optionally have a load
cell (HX711) and a USB audio recorder. A central control PC runs everything over the
network.

It covers the whole process: flashing the SD card, enabling SSH, networking, time
synchronisation, packages, permissions, reliability settings, and checking that the node
is ready to record.

- **Part A** sets everything up by hand and explains each step.
- **Part B** does the same with one script, [`pi_setup.sh`](pi_setup.sh).

Both give the same result. Read Part A once to understand the setup, then use Part B
for each additional node.

---

## Contents

- [How the setup works](#how-the-setup-works)
- [Plan your nodes first](#plan-your-nodes-first)
- [What you need](#what-you-need)
- [Part A — Manual setup](#part-a--manual-setup)
  - [A1. Prepare the control PC](#a1-prepare-the-control-pc-once)
  - [A2. Flash the SD card](#a2-flash-the-sd-card)
  - [A3. First boot and SSH](#a3-first-boot-and-ssh)
  - [A4. SSH key login](#a4-ssh-key-login)
  - [A5. Static IP](#a5-static-ip-with-gateway-and-dns)
  - [A6. Clock and time sync](#a6-clock-and-time-synchronisation)
  - [A7. System update and packages](#a7-system-update-and-packages)
  - [A8. Hardware permissions and RFID readers](#a8-hardware-permissions-and-rfid-readers)
  - [A9. Camera](#a9-camera)
  - [A10. Passwordless sudo (optional)](#a10-passwordless-sudo-optional-not-recommended)
  - [A11. Hardware watchdog](#a11-hardware-watchdog)
  - [A12. Run your logger as a service](#a12-run-your-logger-as-a-service)
  - [A13. Check everything](#a13-check-everything)
- [Part B — Setup with `pi_setup.sh`](#part-b--setup-with-pi_setupsh)
- [Adding more nodes](#adding-more-nodes)
- [Security notes](#security-notes)

---

## How the setup works

```
                     Internet (optional)
                            │
                 ┌──────────┴──────────┐
                 │     Control PC      │  - shares internet with the Pis (optional)
                 │  e.g. 192.168.137.1 │  - NTP time server for the Pis
                 └──────────┬──────────┘  - runs the recording / control software
                            │ Ethernet
                     ┌──────┴──────┐
                     │   Switch    │
                     └──┬───┬───┬──┘
              ┌─────────┘   │   └─────────┐
        ┌─────┴─────┐ ┌─────┴─────┐ ┌─────┴─────┐
        │  Pi node  │ │  Pi node  │ │  Pi node  │   each node:
        │   .140    │ │   .141    │ │   .142    │   - USB RFID readers (+ USB hub)
        └───────────┘ └───────────┘ └───────────┘   - Pi camera (CSI)
                                                    - optional: HX711 load cell, USB audio
```

These requirements drive the setup steps:

| Requirement | Why it matters | Handled in |
|---|---|---|
| A **unique hostname** per node | Identical names clash on the network (`name.local` becomes `name-2.local` at random), and data can end up under the wrong label. | A2 |
| A **fixed IP** per node | The control software connects to each node by IP. | A5 |
| **The same clock on every node** | RFID reads and video from different nodes are combined by timestamp. | A1, A6 |
| **Device permissions** | Without them, the readers fail with *permission denied*. | A8 |
| **Unattended reliability** | Nodes run for days, so they must recover from freezes and power cuts by themselves. | A11, A12 |

---

## Plan your nodes first

Before flashing anything, decide on one naming scheme and one IP range, and write them in a
table. For example, for a site with 4 enclosures × 2 levels:

| Label (control software) | Hostname | IP | Notes |
|---|---|---|---|
| S1-Unit1-lower | s1-unit1-lower | 192.168.137.140 | |
| S1-Unit1-upper | s1-unit1-upper | 192.168.137.141 | |
| S1-Unit2-lower | s1-unit2-lower | 192.168.137.142 | |
| … | … | … | |

Tips:
- **Include a site or room prefix** (`S1-`, `R2-`, …) if you run more than one setup. Two
  setups that both use `Unit1-lower` will overwrite each other's configuration and mix
  their data as soon as they share a PC, a network or an analysis.
- **Give each site its own IP range** (e.g. site 1 `.120–.127`, site 2 `.140–.147`), even if
  the sites are on separate networks today.
- **Hostnames:** lowercase letters, digits and hyphens only. Labels in your software can use
  any case.
- **Use the same username on every node** (e.g. `datauser`). Scripts and paths like
  `/home/<user>/…` then work the same on every node.
- Label each SD card and each Pi with its hostname.

The rest of this guide uses these placeholders:

| Placeholder | Meaning | Example |
|---|---|---|
| `<user>` | Username on every Pi | `datauser` |
| `<hostname>` | This node's hostname | `s1-unit1-upper` |
| `<ip>` | This node's static IP | `192.168.137.141` |
| `<pc-ip>` | Control PC on the Pi network (gateway, DNS, NTP) | `192.168.137.1` |
| `<tz>` | Time zone | `Europe/Berlin`, `Asia/Seoul`, `UTC` |

---

## What you need

**Per node**
- Raspberry Pi 5 + **official 27 W USB-C power supply**. Weaker supplies cause random
  resets and USB dropouts under load (camera + several readers).
- microSD card: a good brand, **A1/A2, 32 GB or larger**. Cheap or counterfeit cards are
  the most common cause of boot failures and corrupted data. Alternatively, use an NVMe SSD
  with an M.2 HAT.
- **RTC battery** (Raspberry Pi 5 RTC battery, ML-2020), strongly recommended. Without it, the
  Pi forgets the time at every power cut until it reaches an NTP server.
- Raspberry Pi camera module + the correct Pi 5 camera cable (the Pi 5 uses the smaller
  22-pin connector).
- USB RFID readers. If you use more readers than USB ports, use a **powered** USB hub.
- Ethernet cable.

**Shared**
- A network switch with enough ports for all nodes + the PC.
- Control PC with **Raspberry Pi Imager** and an SSH client (OpenSSH, built into Windows 10/11).

---

# Part A — Manual setup

## A1. Prepare the control PC (once)

### Network: pick one option

**Option 1 — The PC shares its internet with the Pis (Windows ICS).** This is the simplest
option for an isolated rig. The Pi network becomes `192.168.137.0/24`, and the PC is
`192.168.137.1`.

1. Connect the switch to the PC's Ethernet port.
2. `Win + R` → `ncpa.cpl` → right-click the adapter **that has internet** (e.g. *Wi-Fi*) →
   **Properties** → **Sharing** → tick *Allow other network users to connect through this
   computer's Internet connection* → under *Home networking connection* choose the
   **Ethernet adapter connected to the Pis** → **OK**.
3. Windows gives that Ethernet adapter `192.168.137.1` and hands out temporary addresses to
   the Pis.

> Windows sometimes turns ICS off after a restart or an update. If the Pis lose internet,
> untick the box, click OK, then tick it again. Having `192.168.137.1` on the adapter does
> **not** mean ICS is on; check the Sharing tab.

**Option 2 — Lab router or managed network.** Plug the switch into the router. Then either
reserve one IP per Pi in the router's DHCP settings (and skip A5), or pick static IPs outside
the router's DHCP range. Use the router's IP as `<pc-ip>` for the gateway and DNS, and the
PC's IP as the NTP server.

The Pis only need internet during setup, for `apt`. They can record on a network without
internet access.

### Time server

Every node syncs its clock from the PC. That makes all nodes agree with each other and with
the PC, even without internet.

**Windows: built-in Windows Time service as the NTP server** (run in an **admin** PowerShell):
```powershell
reg add HKLM\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer /v Enabled /t REG_DWORD /d 1 /f
reg add HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config /v AnnounceFlags /t REG_DWORD /d 5 /f
sc.exe config w32time start= auto
net stop w32time; net start w32time
netsh advfirewall firewall add rule name="NTP server (UDP 123)" dir=in action=allow protocol=UDP localport=123
```
For better accuracy, you can install a full NTP server (e.g. the Meinberg build of
`ntpd` for Windows) instead. Either way, **UDP port 123** must be allowed in the firewall.

**Linux PC:** install `chrony` and add `allow 192.168.137.0/24` to `/etc/chrony/chrony.conf`.

## A2. Flash the SD card

1. **Unplug every USB drive from the PC.** The Imager erases whatever disk you select, and a
   USB stick is easy to pick by mistake.
2. Open **Raspberry Pi Imager**:
   - **Device:** Raspberry Pi 5
   - **OS:** **Raspberry Pi OS (64-bit)**. Choose *Raspberry Pi OS (other) → Lite (64-bit)*
     instead if the nodes will never have a monitor. Avoid the 32-bit and Legacy builds:
     they're slower on a Pi 5 and won't match nodes set up from this guide.
   - **Storage:** the SD card. Check the **size and name** (e.g. *SD/MMC*) before continuing.
3. **Customisation** (the important part):
   - **Hostname:** `<hostname>`, different for every node
   - **Username / password:** `<user>` / a strong password, the same on every node
   - **Time zone / keyboard:** `<tz>` / your layout
   - **Wi-Fi:** leave empty if the nodes use Ethernet. If you fill it in, set the correct
     **country**.
   - **SSH:** **enable** (password authentication, or paste your public key)
4. **App Options:** make sure *verify after writing* is on. Write, and **wait for
   verification to finish**.
5. If Windows says *"You need to format the disk…"* afterwards, click **Cancel**. Formatting
   erases the card you just wrote.
6. Eject the card and label it.

> **Flash each card separately** with its own hostname, rather than cloning one finished card
> to the others. A cloned card copies the machine-id, the SSH host keys and the DHCP client ID,
> so nodes can end up with the same IP and SSH shows "host key changed" warnings. If you have
> to clone, see [Adding more nodes](#adding-more-nodes).

> **"Unable to read partition as FAT"** at boot means the card has no valid boot partition,
> usually because the image went to a different disk or the write failed. Reflash with
> verification on; if it fails again, replace the card.

## A3. First boot and SSH

1. Insert the SD card, connect Ethernet, **then** connect power. Wait **2–3 minutes**. The
   first boot expands the file system and may reboot once.
2. From the PC:
   ```powershell
   ssh <user>@<hostname>.local
   ```
   Type `yes` to accept the host key, then enter the password.
   - If the name isn't found, find the Pi's temporary IP in the router or ICS client list, or
     log in with a monitor and keyboard and run `hostname -I`.
3. If you log in with a monitor and SSH isn't running:
   ```bash
   sudo systemctl enable --now ssh
   systemctl status ssh          # active (running)
   ```
4. Check the hostname:
   ```bash
   hostname                      # <hostname>
   ```

## A4. SSH key login

With a key, you (and your control software) can log in without typing the password.

On the **PC**, once:
```powershell
if (!(Test-Path $HOME\.ssh\id_ed25519)) { ssh-keygen -t ed25519 -N '""' -f $HOME\.ssh\id_ed25519 }
```
Then for **each node**:
```powershell
type $HOME\.ssh\id_ed25519.pub | ssh <user>@<hostname>.local "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```
On Linux or macOS, `ssh-copy-id <user>@<hostname>.local` does the same.

If your control software uses its own key, install that key the same way, or use its
key-deployment tool.

## A5. Static IP (with gateway and DNS)

Skip this step if you reserved addresses in the router (A1, option 2).

On the **Pi**:
```bash
sudo nmcli con mod "Wired connection 1" connection.autoconnect no
sudo nmcli con add type ethernet ifname eth0 con-name static-eth0 \
  ipv4.method manual ipv4.addresses <ip>/24 \
  ipv4.gateway <pc-ip> ipv4.dns "<pc-ip> 8.8.8.8" autoconnect yes
sudo nmcli con up static-eth0
```
- Turning off autoconnect on the default profile stops it competing with the static one.
- **Always set the gateway and DNS.** An IP address alone lets the Pi reach the PC but nothing
  else. Then `apt` fails with *"Temporary failure resolving deb.debian.org"* and `ping 8.8.8.8`
  gets no replies.

The SSH session drops when the IP changes. Reconnect with `ssh <user>@<ip>`, then check:
```bash
hostname -I                     # <ip>
ip route | head -1              # default via <pc-ip> dev eth0
ping -c 3 8.8.8.8               # replies (only if the PC/router provides internet)
```

## A6. Clock and time synchronisation

Without an RTC battery, a Pi that boots without network has the wrong time, and HTTPS and
`apt` can fail because of it. Fix the clock by hand first if it's far off:
```bash
date
sudo date -s "YYYY-MM-DD HH:MM"
sudo timedatectl set-timezone <tz>
```

Raspberry Pi OS already includes **`systemd-timesyncd`**. Point it at the PC:
```bash
sudo mkdir -p /etc/systemd/timesyncd.conf.d
printf '[Time]\nNTP=<pc-ip>\nFallbackNTP=\n' | sudo tee /etc/systemd/timesyncd.conf.d/local-ntp.conf
sudo timedatectl set-ntp true
sudo systemctl restart systemd-timesyncd
```
Check it:
```bash
timedatectl timesync-status     # Server: <pc-ip>, Packet count > 0
timedatectl                     # System clock synchronized: yes
```
If `Packet count` stays at 0, the PC isn't answering NTP. Check the time service and the
UDP 123 firewall rule (A1).

**Do you need chrony instead?** Usually not. timesyncd keeps the nodes within a few
milliseconds of each other, which is plenty for RFID reads and video. Use `chrony` only if
you need sub-millisecond agreement, for example for frame-level sync between cameras.
Notes if you do:
- chrony **replaces** timesyncd. `dpkg -i chrony_*.deb` fails with *"conflicts with
  time-daemon"*. Install it with `sudo apt install chrony`, or
  `sudo apt install /tmp/chrony_*.deb` for an offline file, and apt will remove timesyncd.
- Use the `.deb` built for **your** Debian release. Raspberry Pi OS based on Trixie needs a
  `+deb13` package; a `+deb12` package is for Bookworm.
- Copy offline `.deb` files to `/tmp` before installing. apt can't read files in your home
  folder (*"Permission denied"*).

## A7. System update and packages

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y python3-serial python3-rpi-lgpio python3-numpy \
                    rpicam-apps ffmpeg socat alsa-utils vim tmux
sudo rpi-eeprom-update -a        # bootloader update, applied at the next reboot
sudo reboot
```

| Package | Purpose |
|---|---|
| `python3-serial` | Read USB-serial RFID readers from Python (`import serial`) |
| `python3-rpi-lgpio` | `RPi.GPIO`-compatible library that **works on the Pi 5** (e.g. HX711 load cells). The original `RPi.GPIO` does not support the Pi 5. |
| `python3-numpy` | Numerical processing (e.g. audio, sensor data) |
| `rpicam-apps` | Camera tools: `rpicam-hello`, `rpicam-vid`, `rpicam-still` |
| `ffmpeg`, `socat` | Encode, record and forward camera streams |
| `alsa-utils` | `arecord` / `aplay` for USB audio recorders |
| `vim`, `tmux` | Editing, and terminal sessions that survive SSH disconnects |

Several of these come preinstalled on the Desktop image. Installing them again does no harm.

> Run long upgrades inside `tmux`. If SSH drops in the middle of an upgrade, the process can
> be killed while packages are half-installed. If that happens, run
> `sudo dpkg --configure -a`, then check that `sudo dpkg --audit` reports nothing.

## A8. Hardware permissions and RFID readers

Add the user to the hardware groups:
```bash
sudo usermod -aG dialout,gpio,i2c,spi,video,audio <user>
```

| Group | Gives access to |
|---|---|
| `dialout` | USB-serial devices: **RFID readers** (`/dev/ttyUSB*`, `/dev/ttyACM*`) |
| `gpio`, `i2c`, `spi` | GPIO pins and buses (load cells, sensors) |
| `video` | Camera |
| `audio` | USB audio recorders |

Log out and back in (or reboot) for this to take effect, then check with `groups`.

Enable I2C or SPI only if a device needs it:
```bash
sudo raspi-config nonint do_i2c 0
sudo raspi-config nonint do_spi 0
```

### Getting the same name for each reader every time

Linux numbers USB-serial devices (`ttyUSB0`, `ttyUSB1`, …) in the order it detects them. The
numbers **can swap** after a reboot or when you reconnect a reader. Never map readers to
physical zones by `ttyUSBn`. Instead:

```bash
ls -l /dev/serial/by-path/      # named by USB port, so it's the same as long as the cable is in the same socket
ls -l /dev/serial/by-id/        # named by serial number, but only if the adapter has one
```
- Many cheap USB-serial chips (e.g. **CH340**) have **no serial number**, so `by-id` can't tell
  them apart. Use **`by-path`**, and keep each reader plugged into the **same USB socket and
  hub port**. Label the cables.
- For fixed names, add a udev rule, e.g. `/etc/udev/rules.d/99-rfid.rules`:
  ```
  SUBSYSTEM=="tty", KERNELS=="1-1.2:1.0", SYMLINK+="rfid-zone1"
  ```
  Find the `KERNELS` value with `udevadm info -a -n /dev/ttyUSB0 | grep KERNELS`, then run
  `sudo udevadm control --reload && sudo udevadm trigger`.

Quick test that a reader works:
```bash
python3 -c "import serial; s=serial.Serial('/dev/ttyUSB0', 9600, timeout=5); print(s.read(64))"
```
Set the baud rate your reader uses, then hold a tag near the antenna.

## A9. Camera

Check that the camera is detected and can record:
```bash
rpicam-hello --list-cameras
rpicam-vid -t 5000 -o /tmp/test.h264          # 5-second test clip
```
If no camera is listed, power off and reseat the cable. The Pi 5 needs the narrow 22-pin
cable, and the contacts must face the right way.

If you **stream video over the network** (e.g. UDP/TCP to the control PC), make the socket
buffers larger. The defaults are small and cause dropped frames at high bitrates:
```bash
sudo tee /etc/sysctl.d/90-camera-stream.conf <<'EOF'
net.core.rmem_max=134217728
net.core.rmem_default=16777216
net.core.wmem_max=134217728
net.core.wmem_default=16777216
net.ipv4.udp_rmem_min=262144
net.ipv4.udp_wmem_min=262144
EOF
sudo sysctl -p /etc/sysctl.d/90-camera-stream.conf
```
Setting these in a file means they apply at every boot, so your control software doesn't
need `sudo` to set them.

## A10. Passwordless sudo (optional, not recommended)

Raspberry Pi OS **no longer** lets the default user run `sudo` without a password. Some control
software runs `sudo -n …` on the nodes (for example to correct the clock, change sysctl
settings or restart a service). `-n` means "fail instead of asking for a password", so these
commands **fail silently** when no rule allows them.

**First, avoid needing it:**
- Clock: time sync (A6) and an RTC battery keep the clock right without `sudo date`.
- sysctl: the settings file in A9 applies at boot.
- Services: set up your service once with sudo during setup (A12). Then they don't need to be
  restarted remotely.

**If your software still needs it,** allow only the specific commands, never `ALL`:
```bash
echo '<user> ALL=(root) NOPASSWD: /usr/bin/date, /usr/bin/timedatectl' | sudo tee /etc/sudoers.d/020_datacollect
sudo chmod 440 /etc/sudoers.d/020_datacollect
sudo visudo -c                  # must say "parsed OK"
sudo -k; sudo -n date           # test: prints the date without a password prompt
```
Add `/usr/sbin/sysctl` or `/usr/bin/systemctl` only if you really need them. **Passwordless
`systemctl` is effectively full root access.** Only allow it on an isolated network with a
strong password.

## A11. Hardware watchdog

The Pi 5 has a hardware watchdog. With it enabled, the Pi **reboots itself if it freezes**,
instead of sitting dead until someone notices.
```bash
sudo mkdir -p /etc/systemd/system.conf.d
printf '[Manager]\nRuntimeWatchdogSec=15\nRebootWatchdogSec=2min\n' | sudo tee /etc/systemd/system.conf.d/watchdog.conf
sudo systemctl daemon-reexec
systemctl show -p RuntimeWatchdogUSec     # RuntimeWatchdogUSec=15s
```

## A12. Run your logger as a service

If your recording script runs on the Pi itself, rather than being started remotely by the
control PC, run it as a **systemd service**. It then starts at boot, restarts if it crashes,
and keeps running after power cuts and SSH disconnects. Example
`/etc/systemd/system/rfid-logger.service`:
```ini
[Unit]
Description=RFID logger
After=network-online.target time-sync.target
Wants=network-online.target

[Service]
User=<user>
WorkingDirectory=/home/<user>
ExecStart=/usr/bin/python3 /home/<user>/rfid_logger.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rfid-logger
journalctl -u rfid-logger -f        # live log
```
If the control PC uploads and starts the scripts over SSH instead, skip this step. Make sure
the user has the permissions from A8.

**Data safety:** write data to files in small, frequent appends (or rotate files hourly or
daily), and fetch them to the PC regularly. SD cards can wear out or corrupt, so don't keep
the only copy on the Pi.

## A13. Check everything

```bash
hostname                                    # <hostname>
hostname -I                                 # <ip>
groups                                      # dialout gpio i2c spi video audio …
timedatectl                                 # <tz>, System clock synchronized: yes
timedatectl timesync-status | head -3       # Server: <pc-ip>
systemctl show -p RuntimeWatchdogUSec       # 15s
sysctl net.core.rmem_max                    # 134217728 (if A9 applied)
python3 -c "import serial, numpy, RPi.GPIO; print('python OK')"
rpi-eeprom-update | grep BOOTLOADER         # up to date
rpicam-hello --list-cameras                 # camera listed
ls -l /dev/serial/by-path/                  # one entry per RFID reader
arecord -l                                  # audio device listed (if used)
```
Then do a short end-to-end test from the control PC: record for a few minutes, scan a tag on
each reader, and check that the reads, the video and the timestamps all arrive and line up.

---

# Part B — Setup with `pi_setup.sh`

[`pi_setup.sh`](pi_setup.sh) does **A5–A11** in one go: hostname, time sync, packages,
groups, camera buffers, watchdog and static IP. Passwordless sudo is optional and
off unless you ask for it. The script is safe to run more than once.

1. Prepare the PC (**A1**) and flash the card (**A2**) with the node's hostname, your user, and
   SSH on.
2. Boot the Pi, wait 2–3 minutes, then copy the script over and log in:
   ```powershell
   scp pi_setup.sh <user>@<hostname>.local:~
   ssh <user>@<hostname>.local
   ```
3. Run it on the Pi:
   ```bash
   sudo bash ~/pi_setup.sh --hostname <hostname> --ip <ip> --gateway <pc-ip> --tz <tz>
   ```
   The SSH session drops at the end when the static IP takes effect. That's expected.
4. Reconnect and finish:
   ```powershell
   ssh <user>@<ip>
   ```
   ```bash
   sudo apt full-upgrade -y
   sudo rpi-eeprom-update -a
   sudo reboot
   ```
5. Run the checks in **A13**.

### Options

| Option | Default | Meaning |
|---|---|---|
| `--hostname NAME` | *(required)* | Node hostname |
| `--ip ADDR` | *(none)* | Static IPv4 for the interface. Without it, the network is left unchanged. |
| `--prefix N` | `24` | Subnet prefix length |
| `--gateway ADDR` | `192.168.137.1` | Gateway (the PC with ICS, or your router) |
| `--dns "A B"` | `"<gateway> 8.8.8.8"` | DNS servers |
| `--iface NAME` | `eth0` | Ethernet interface |
| `--ntp ADDR` | the gateway | NTP server |
| `--tz ZONE` | `UTC` | Time zone |
| `--user NAME` | the user who ran `sudo` | Account that gets the hardware groups |
| `--no-packages` | | Skip package installation (offline setup) |
| `--no-sysctl` | | Skip the camera network buffer settings |
| `--no-watchdog` | | Don't enable the hardware watchdog |
| `--nopasswd-sudo` | off | Add the sudo rule from A10 (`date`, `timedatectl`, `sysctl`, `systemctl`) |

Example with a lab router at `10.0.0.1` and a PC time server at `10.0.0.5`:
```bash
sudo bash ~/pi_setup.sh --hostname s1-unit3-lower --ip 10.0.0.53 \
     --gateway 10.0.0.1 --dns "10.0.0.1" --ntp 10.0.0.5 --tz Europe/Berlin
```

> The script needs internet only to install missing packages. Use `--no-packages` on a fully
> offline network. If `apt` fails because the clock is wrong, set it first with
> `sudo date -s "YYYY-MM-DD HH:MM"`.

---

## Adding more nodes

- Repeat **A2 → Part B** for each node, using the next hostname and IP from your table.
- Keep all nodes on the **same OS image and the same upgrade level**, so they behave the same.
- If you **cloned** a card instead of flashing it, give the clone a new identity before
  putting it on the network:
  ```bash
  sudo rm -f /etc/machine-id /var/lib/dbus/machine-id && sudo systemd-machine-id-setup
  sudo rm -f /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server
  ```
  Then set the hostname and IP (Part B).
- After reflashing a node that keeps its old IP, the PC will warn *"REMOTE HOST IDENTIFICATION
  HAS CHANGED"*. That's expected. Remove the old key with `ssh-keygen -R <ip>` (and
  `ssh-keygen -R <hostname>.local`).
- Add each node to your control software's node list (label, IP, user, port), and keep that
  list in sync with your planning table.

## Security notes

- Nodes on an isolated rig network are fine with password SSH. **Don't expose them** to a
  building network or the internet with a shared or simple password.
- Don't commit passwords, Wi-Fi keys or node lists containing passwords to a public repository.
- Prefer SSH keys (A4). Once every client uses keys, you can turn off password login in
  `/etc/ssh/sshd_config.d/`.
- Keep passwordless sudo (A10) as narrow as possible, or leave it off.
