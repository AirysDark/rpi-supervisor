#!/bin/bash
set -euo pipefail

# ============================================================
# Rpi Supervisor Unified Installer (Node + Fleet)
# ============================================================

INSTALL_DIR="/opt/rpi-supervisor"
FLEET_DIR="/opt/rpi-supervisor-fleet"

BIN_DIR="${INSTALL_DIR}/bin"
SERVICE_FILE="/etc/systemd/system/rsupd.service"
FLEET_SERVICE_FILE="/etc/systemd/system/rsup-fleetd.service"

CONF_FILE="/etc/rpi-supervisor/supervisor.conf"
DEVICE_FILE="/etc/rpi-supervisor/device.json"
FLEET_KEYS="${FLEET_DIR}/rsup-fleet-keys.json"

SOURCE_DIR="/run/rpi-supervisor"

BOOTCFG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"

if [ -f /boot/firmware/config.txt ]; then
  BOOTCFG="/boot/firmware/config.txt"
  CMDLINE="/boot/firmware/cmdline.txt"
fi

# ============================================================
# Require root
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo ./install.sh)"
  exit 1
fi

clear

# ============================================================
# WELCOME SCREEN
# ============================================================

echo "============================================================"
echo "              RPI SUPERVISOR INSTALLER"
echo "============================================================"
echo ""
echo "This installer can deploy:"
echo ""
echo "  NODE  → Install Rpi Supervisor on a Raspberry Pi"
echo "  FLEET → Install Fleet Server"
echo ""
echo "============================================================"
read -n 1 -s -r -p "Press any key to continue..."
echo ""
echo ""

# ============================================================
# MODE SELECTION
# ============================================================

echo "Select installation type:"
echo "  node"
echo "  fleet"
echo ""

read -p "Type (node/fleet): " MODE
MODE=$(echo "$MODE" | tr '[:upper:]' '[:lower:]')

if [[ "$MODE" != "node" && "$MODE" != "fleet" ]]; then
  echo "Invalid selection."
  exit 1
fi

echo ""
echo "============================================================"
echo "Selected: $MODE"
echo "============================================================"
read -n 1 -s -r -p "Press any key to continue..."
echo ""
echo ""

mount -o remount,rw / || true
mount -o remount,rw /boot 2>/dev/null || true

echo "[1/15] Installing dependencies..."

apt-get update -y
apt-get install -y \
    python3 \
    python3-gpiozero \
    python3-sdnotify \
    git \
    watchdog \
    jq

# ============================================================
# NODE INSTALLATION
# ============================================================

if [[ "$MODE" == "node" ]]; then

echo "[2/15] Copying node file structure from ${SOURCE_DIR}..."

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "ERROR: ${SOURCE_DIR} does not exist."
  exit 1
fi

mkdir -p "${INSTALL_DIR}"

cp -a "${SOURCE_DIR}/opt/rpi-supervisor/." "${INSTALL_DIR}/" || true
[ -d "${SOURCE_DIR}/etc" ] && cp -a "${SOURCE_DIR}/etc/." /etc/ || true
[ -d "${SOURCE_DIR}/var" ] && cp -a "${SOURCE_DIR}/var/." /var/ || true
[ -d "${SOURCE_DIR}/usr" ] && cp -a "${SOURCE_DIR}/usr/." /usr/ || true
[ -f "${SOURCE_DIR}/README.md" ] && cp -a "${SOURCE_DIR}/README.md" /root/ || true
[ -f "${SOURCE_DIR}/install.sh" ] && cp -a "${SOURCE_DIR}/install.sh" /root/ || true

echo "[3/15] Installing systemd service..."
install -m 0644 "${SOURCE_DIR}/etc/systemd/system/rsupd.service" "${SERVICE_FILE}"
systemctl daemon-reload

SHUTDOWN_PIN=17
RESET_PIN=27
SAFEPOWER_PIN=22
POWER_FAIL_PIN=23

echo "[4/15] GPIO configuration"
echo "Mode: yes / no / input"
read -p "Selection: " GPIO_MODE
GPIO_MODE=$(echo "${GPIO_MODE:-yes}" | tr '[:upper:]' '[:lower:]')

if [[ "$GPIO_MODE" == "input" ]]; then
  read -p "SHUTDOWN_PIN= " SHUTDOWN_PIN
  read -p "RESET_PIN= " RESET_PIN
  read -p "SAFEPOWER_PIN= " SAFEPOWER_PIN
  read -p "POWER_FAIL_PIN= " POWER_FAIL_PIN
fi

echo "[5/15] Applying GPIO overlays..."

sed -i '/^dtoverlay=gpio-shutdown/d' "${BOOTCFG}" || true
sed -i '/^dtoverlay=gpio-safepower/d' "${BOOTCFG}" || true
sed -i '/^gpio=.*=op,dl$/d' "${BOOTCFG}" || true

echo "dtoverlay=gpio-shutdown,gpio_pin=${SHUTDOWN_PIN},active_low=1,gpio_pull=up" >> "${BOOTCFG}"
echo "dtoverlay=gpio-safepower,gpiopin=${SAFEPOWER_PIN},active_low=0" >> "${BOOTCFG}"
echo "gpio=${SAFEPOWER_PIN}=op,dl" >> "${BOOTCFG}"

echo "[6/15] Configuring kernel panic..."
grep -q "panic=5" "${CMDLINE}" || sed -i '1 s/$/ panic=5/' "${CMDLINE}"
grep -q "printk.devkmsg=on" "${CMDLINE}" || sed -i '1 s/$/ printk.devkmsg=on/' "${CMDLINE}"

echo "[7/15] Configuring watchdog..."
grep -q "^dtparam=watchdog=on" "${BOOTCFG}" || echo "dtparam=watchdog=on" >> "${BOOTCFG}"

cat > /etc/watchdog.conf <<EOF
watchdog-device = /dev/watchdog
watchdog-timeout = 15
interval = 5
EOF

systemctl enable watchdog
systemctl restart watchdog

echo "[8/15] Enabling rsupd..."
systemctl enable rsupd.service
systemctl restart rsupd.service

echo "[9/15] Device Identity"
read -p "device_id: " DEVICE_ID
read -p "role: " ROLE
read -p "site: " SITE

mkdir -p /etc/rpi-supervisor

cat > "${DEVICE_FILE}" <<EOF
{
  "device_id": "${DEVICE_ID}",
  "role": "${ROLE}",
  "site": "${SITE}"
}
EOF

chmod 600 "${DEVICE_FILE}"

echo "[10/15] Generating device key..."
GENERATED_KEY=$("${INSTALL_DIR}/bin/rsup-gen-device-key" | tr -d '\n')

echo ""
echo "Device Key:"
echo "${GENERATED_KEY}"
echo ""
echo "Register this on your Fleet Server manually."

fi

# ============================================================
# FLEET INSTALLATION
# ============================================================

if [[ "$MODE" == "fleet" ]]; then

echo "[2/15] Copying fleet file structure from ${SOURCE_DIR}..."

if [ ! -d "${SOURCE_DIR}/opt/rpi-supervisor-fleet" ]; then
  echo "ERROR: Fleet source missing."
  exit 1
fi

mkdir -p "${FLEET_DIR}"
cp -a "${SOURCE_DIR}/opt/rpi-supervisor-fleet/." "${FLEET_DIR}/"

echo "[3/15] Installing fleet service..."
install -m 0644 "${SOURCE_DIR}/etc/systemd/system/rsup-fleetd.service" "${FLEET_SERVICE_FILE}"
systemctl daemon-reload
systemctl enable rsup-fleetd.service
systemctl restart rsup-fleetd.service

if [ ! -f "${FLEET_KEYS}" ]; then
  echo "[4/15] Creating fleet key database..."
  mkdir -p "${FLEET_DIR}"
  cat > "${FLEET_KEYS}" <<EOF
{
  "devices": {}
}
EOF
fi

echo "Fleet installation complete."

fi

echo ""
echo "============================================================"
echo "Installation complete."
echo "============================================================"
echo "Reboot recommended:"
echo "  reboot"
echo ""