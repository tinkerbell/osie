#!/bin/bash

source functions.sh && init

USAGE="Usage: $0 -t /mnt/target -k url
Required Arguments:
	-a arch      System architecture {aarch64|x86_64}
	-k url       Address of tinkerbell
	-t target    Target mount point to write network configs to
	-M metadata  File containing instance metadata

Options:
	-h           This help message
	-v           Turn on verbose messages for debugging

Description: This script will configure extras on suse based distros
"
while getopts "a:k:M:t:hv" OPTION; do
	case $OPTION in
	a) arch=$OPTARG ;;
	k) tinkerbell=$OPTARG ;;
	M) metadata=$OPTARG ;;
	t) export TARGET="$OPTARG" ;;
	h) echo "$USAGE" && exit 0 ;;
	v) set -x ;;
	*) echo "$USAGE" && exit 1 ;;
	esac
done

check_required_arg "$metadata" "metadata file" "-M"
check_required_arg "$arch" "arch" "-a"
check_required_arg "$tinkerbell" "tinkerbell url" "-k"
check_required_arg "$TARGET" "target mount point" "-t"
assert_all_args_consumed "$OPTIND" "$@"

# Make sure target provided is mounted
if grep -qs "$TARGET" /proc/mounts; then
	echo "Target is mounted... good."
else
	echo "Error: Target $TARGET is not mounted"
	exit 1
fi

os_ver=$(detect_os "$TARGET")
# shellcheck disable=SC2086
set -- $os_ver
DOS=$1
DVER=$2
echo "#### Detected OS on mounted target $TARGET"
echo "OS: $DOS  ARCH: $arch VER: $DVER"

# Match detected OS to known OS config
if [[ $DOS == "SUSE" ]] || [[ $DOS == "SUSELINUX" ]] || [[ $DOS == "openSUSEproject" ]]; then
	echo "Configuring SUSE based distro extras"
else
	echo "Error: Detected OS $DOS not matched"
	exit 1
fi

cat >>"$TARGET/etc/sysctl.conf" <<EOF
# set default and maximum socket buffer sizes to 12MB
net.core.rmem_default=$((12 * 1024 * 1024))
net.core.wmem_default=$((12 * 1024 * 1024))
net.core.rmem_max=$((12 * 1024 * 1024))
net.core.wmem_max=$((12 * 1024 * 1024))

# set minimum, default, and maximum tcp buffer sizes (10k, 87.38k (linux default), 12M resp)
net.ipv4.tcp_rmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))
net.ipv4.tcp_wmem=$((10 * 1024)) 87380 $((12 * 1024 * 1024))

# Enable TCP westwood for kernels greater than or equal to 2.6.13
net.ipv4.tcp_congestion_control=westwood
EOF

sed -i 's/GSSAPIAuthentication yes/GSSAPIAuthentication no/g' "$TARGET/etc/ssh/sshd_config"

echo "ttyS1" >>"$TARGET/etc/securetty"
if [[ $arch == 'aarch64' ]]; then
	echo "ttyAMA0" >>"$TARGET/etc/securetty"
fi

cat <<EOF_UNIT >"$TARGET/usr/lib/systemd/system/cloud-init.service"
[Unit]
Description=Initial cloud-init job (metadata service crawler)
Requires=network.target
Wants=local-fs.target cloud-init-local.service
After=local-fs.target network.target cloud-init-local.service

[Service]
Type=oneshot
ExecStart=/usr/bin/cloud-init init
RemainAfterExit=yes
TimeoutSec=0

# Output needs to appear in instance console output
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF_UNIT
ln -sf /usr/lib/systemd/system/cloud-init.service "$TARGET/etc/systemd/system/multi-user.target.wants/cloud-init.service"

cat <<EOF_ET >"$TARGET/bin/phone-home.sh"
#!/bin/bash
logger -s -t phone_home "Making a call to tell the packet API is online."
# doesn't hurt to log as much as we can in case it fails.
n=1
until [ \$n -ge 6 ] || [ "\${PIPESTATUS[0]}" -eq 0 ]; do
	curl -X PUT -H "Content-Type: application/json" -vs -d '{"instance_id": "$(jq -r .id "$metadata")"}' "$tinkerbell/phone-home" 2>&1 | logger -s -t phone_home
	if [ \${PIPESTATUS[0]} -eq 0 ]; then
		logger -s -t phone_home "This device has been announced to the packet API."
		break
	else
		logger -s -t phone_home "phone-home command execution (retry \$n / 5) failed."
	fi
	n=\$((n + 1))
	sleep 30
done
unlink /etc/systemd/system/multi-user.target.wants/phone-home.service
unlink /etc/systemd/system/phone-home.service
rm /lib/systemd/system/phone-home.service
rm /bin/phone-home.sh
EOF_ET

chmod 700 "$TARGET/bin/phone-home.sh"

# SUSE has a different ssh service name
echo -e 'system_info:\n  ssh_svcname: sshd' >"$TARGET/etc/cloud/cloud.cfg.d/99-ssh.cfg"

# Remove dockerinit and dockerenv to address erroneous virt-what answer
rm -f "$TARGET/.dockerinit"
rm -f "$TARGET/.dockerenv"

# Add performance tuning config if tuned is present
if [ -d "/etc/tuned" ]; then
	echo "throughput-performance" >/etc/tuned/active_profile
fi

# Setup license for SLES12 and later SPs
if [[ $DOS == "SUSELINUX" ]] || [[ $DOS == "SUSE" ]]; then
	echo -e "${GREEN}#### Adding license config${NC}"

	# Get latest SMT setup helper from SMT server
	#TODO: make this use facility once we have more than one!
	smtserver=suse-smt.sjc1.packet.net
	ensure_reachable "$smtserver"

	smt_setup=$(curl http://$smtserver/repo/tools/clientSetup4SMT.sh)
	echo "$smtserver" >"$TARGET/var/cache/smt-server"
	if [ -n "$smt_setup" ]; then
		echo "Retrieived SMTSetup from SMT server..."
		echo "$smt_setup" >"$TARGET/var/cache/clientSetup4SMT.sh"
		chmod +x "$TARGET/var/cache/clientSetup4SMT.sh"
	else
		echo "Error: Could not retrieve SMT setup script!"
	fi

	# Get remote SMT CA from SMT server
	#TODO: make this use facility once we have more than one!
	smt_crt=$(curl http://$smtserver/certs/smt.crt.sha)
	if [ -n "$smt_crt" ]; then
		echo "Retrieived remote SMT certificate SHA1 from SMT server..."
		echo "$smt_crt" >"$TARGET/var/cache/smt-remote.crt.sha"
	else
		echo "Error: Could not retrieve SMT certificate!"
	fi

	# Add license service for systemd
	cat <<-EOF_UNIT >"$TARGET/usr/lib/systemd/system/packet-license.service"
		[Unit]
		Description=Initial packet-license activation helper
		Requires=network.target
		Before=cloud-init.service
		
		[Service]
		Type=oneshot
		ExecStart=/usr/bin/packet-license
		TimeoutSec=0
		StandardOutput=journal+console
		
		[Install]
		WantedBy=multi-user.target
	EOF_UNIT

	cat <<-'EOF_pl' >"$TARGET/usr/bin/packet-license"
		#!/bin/bash
		
		smtcrtshafile="/var/cache/smt-remote.crt.sha"
		smtserverfile="/var/cache/smt-server"
		
		if [ -f $smtcrtshafile ]; then
			casha=$(cat $smtcrtshafile)
		else
			echo "Could not find SMT cert file: $smtcrtshafile"
		fi
		
		if [ -f $smtserverfile ]; then
			smtserver=$(cat $smtserverfile)
		else
			echo "Could not find SMT server file: $smtserverfile"
		fi
		
		# syntax: fail 1.2.3.4 '{"fail":"something is wrong"}'
		function fail() {
			local tink_host=$1
			shift
		
			puttink "${tink_host}" phone-home '{"type":"failure", "reason":"'"$1"'"}'
		}
		
		# syntax: puttink 1.2.3.4 phone-home '{"this": "data"}'
		function puttink() {
			local tink_host=$1
			local endpoint=$2
			local post_data=$3
		
			curl \
				-f \
				-vvvvv \
				-X PUT \
				-H "Content-Type: application/json" \
				-d "${post_data}" \
				"${tink_host}/${endpoint}"
		}
		
		function register_smt () {
			local smt_server=$1
			local casha_fingerprint=$2
			local command="/var/cache/clientSetup4SMT.sh --host $smt_server --regcert http://$smt_server/certs/smt.crt --yes --fingerprint $casha_fingerprint"
			local retries=10
			local wait_retry=5
			local act_status=0
		
			# Clean and deregister first
			SUSEConnect --de-register
			SUSEConnect --cleanup
		
			for i in $(seq 1 $retries); do
				echo "$command"
				$command
				ret_value=$?
				if [ $ret_value -eq 0 ]; then
					act_status=1 ; break
				fi
				echo "> failed with $ret_value, waiting to retry..."
				sleep $wait_retry
			done
			if [ $act_status -ne 1 ]; then
				echo "Activation retries $retries/$retries failed."
				fail "$tinkerbell" 'smt_registration_failed'
			else
		        	smtregstatus=$(SUSEConnect -s | awk -F: '{print $5}' | awk -F} '{print $1}' | sed 's/"//g')
		        	if [[ $smtregstatus =~ ^Registered ]]; then
					echo "SMT registration was successful!"
				else
					echo "SMT registration could not be verified. Status: $(echo "$smtregstatus")"
					fail "$tinkerbell" '{"fail":"smt_setup_status_not_verified"}'
				fi
			fi
			rm -f $smtcrtshafile
			rm -f $smtserverfile
		}
		
		register_smt "$smtserver" "$casha"
	EOF_pl
	chmod +x "$TARGET/usr/bin/packet-license"

	# Enable license service
	ln -s /usr/lib/systemd/system/packet-license.service "$TARGET/etc/systemd/system/packet-license.service"
	ln -s /usr/lib/systemd/system/packet-license.service "$TARGET/etc/systemd/system/multi-user.target.wants/packet-license.service"

fi
