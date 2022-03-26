#!/bin/bash -e

if [[ $(id -u) -ne 0 ]] ; then echo "Please run as root" ; exit 1 ; fi
read -p "HOSTNAME [$(hostname)]: " HOSTNAME
raspi-config nonint do_hostname ${HOSTNAME:-$(hostname)}

CURRENT_PRETTY_HOSTNAME=$(hostnamectl status --pretty)
read -p "PRETTY_HOSTNAME [${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}]: " PRETTY_HOSTNAME
hostnamectl set-hostname --pretty "${PRETTY_HOSTNAME:-${CURRENT_PRETTY_HOSTNAME:-Raspberry Pi}}"

echo "Updating packages"
apt update
apt upgrade -y
cat <<'EOF' > /etc/bluetooth/main.conf
[General]
Class = 0x200428
DiscoverableTimeout = 0
[Policy]
AutoEnable=true
EOF
echo "Restarting bluetooth"
invoke-rc.d bluetooth restart
echo "Installing bluez-alsa"
apt install git automake autoconf build-essential libtool pkg-config libasound2-dev libbluetooth-dev libdbus-1-dev libglib2.0-dev libsbc-dev libopenaptx-dev bluez-tools
if [ ! -d "./bluez-alsa" ] 
then
    git clone https://github.com/Arkq/bluez-alsa.git
fi
cd ./bluez-alsa
autoreconf --install --force
if [ -d "./build" ]
then
    rm -rf ./build
fi
mkdir build
cd build
# Only install aptX codec, TODO: add LDAC
../configure --enable-aptx --enable-aptx-hd --with-libopenaptx
make
make install
cd ../..
echo "Adding bluez-alsa services"
cat <<'EOF' > /etc/systemd/system/bluealsa.service
[Unit]
Description=Bluealsa daemon
Documentation=https://github.com/Arkq/bluez-alsa/
After=dbus-org.bluez.service
Requires=dbus-org.bluez.service

[Service]
Type=dbus
BusName=org.bluealsa
EnvironmentFile=-/etc/default/bluealsa
ExecStart=/usr/bin/bluealsa -p a2dp-sink
Restart=on-failure
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RemoveIPC=true
RestrictAddressFamilies=AF_UNIX AF_BLUETOOTH

[Install]
WantedBy=bluetooth.target
EOF
systemctl enable --now bluealsa.service
cat <<'EOF' > /etc/systemd/system/bluealsa-aplay.service
[Unit]
Description=Bluealsa audio player
Documentation=https://github.com/Arkq/bluez-alsa/
Wants=bluealsa.service

[Service]
Type=simple
Environment="BT_ADDR=00:00:00:00:00:00"
EnvironmentFile=-/etc/default/bluealsa-aplay
ExecStart=/usr/bin/bluealsa-aplay $BT_ADDR
Restart=on-failure
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RemoveIPC=true
RestrictAddressFamilies=AF_UNIX

[Install]
WantedBy=bluetooth.target
EOF
systemctl enable --now bluealsa-aplay.service
echo "Adding bluetooth agent"
echo -n "Set 4 digit bluetooth pin code, leave empty if no pin required: "
read REPLY
REGEX='^[0-9]{4}$'
if [[ ! "$REPLY" =~ $REGEX ]]
then
cat <<'EOF' > /etc/bluetooth/pin.conf
* *
EOF
echo "No pin configured"
else
cat <<EOF > /etc/bluetooth/pin.conf
* $REPLY
EOF
echo "Pin is valid and is now configured"
fi
chown root:root /etc/bluetooth/pin.conf
chmod 600 /etc/bluetooth/pin.conf
cat <<'EOF' > /etc/systemd/system/bt-agent.service
[Unit]
Description=Bluetooth Auth Agent
After=bluealsa.service
PartOf=bluetooth.service

[Service]
Type=simple
ExecStartPre=/bin/hciconfig hci0 piscan
ExecStartPre=/bin/hciconfig hci0 sspmode 0
ExecStartPre=/usr/bin/bluetoothctl discoverable on
ExecStart=/usr/bin/bt-agent -c NoInputNoOutput -p /etc/bluetooth/pin.conf
RestartSec=5
Restart=always
KillSignal=SIGUSR1

[Install]
WantedBy=bluetooth.target
EOF
systemctl enable --now bt-agent.service
# Copy files
cp tent.wav /media/success.wav
cp burlap.wav /media/fail.wav
chmod 644 /media/success.wav
chmod 644 /media/fail.wav
# Bluetooth udev script
cat <<'EOF' > /usr/local/bin/bluetooth-udev
#!/bin/bash
logger bluetooth action "$ACTION" triggered by "$NAME"
action=$(expr "$ACTION" : "\([a-zA-Z]\+\).*")
if [ "$action" = "add" ]; then
    bluetoothctl discoverable off
    logger playing /media/success.wav
    amixer -q -M sset Headphone 50%
    aplay /media/success.wav
    amixer -q -M sset Headphone 100%
fi
if [ "$action" = "remove" ]; then
    bluetoothctl discoverable on
    logger playing /media/fail.wav
    amixer -q -M sset Headphone 50%
    aplay /media/fail.wav
    amixer -q -M sset Headphone 100%
fi
EOF
chmod 755 /usr/local/bin/bluetooth-udev

cat <<'EOF' > /etc/udev/rules.d/99-bluetooth-udev.rules
SUBSYSTEM=="input", GROUP="input", MODE="0660"
KERNEL=="input[0-9]*", RUN+="/usr/local/bin/bluetooth-udev"
EOF
echo "Reloading udev rules"
udevadm control --reload-rules