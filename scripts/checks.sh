#!/bin/bash
DIAGNOSE_VERSION=4.17.0
# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile
# shellcheck disable=SC1091
source /usr/sbin/resin-vars
# shellcheck disable=SC1091
source /etc/os-release

# Determine whether we're using the older 'rce'-aliased docker or not.
# stolen directly from the proxy:
# (https://github.com/balena-io/resin-proxy/blob/master/src/common/host-scripts.ts#L28)
X=/usr/bin/
ENG=rce
[ -x $X$ENG ] || ENG=docker
[ -x $X$ENG ] || ENG=balena
[ -x $X$ENG ] || ENG=balena-engine

TIMEOUT=10
TIMEOUT_CMD="timeout --kill-after=$(( TIMEOUT * 2 )) ${TIMEOUT}"
mountpoint="/var/lib/${ENG}"

external_fqdn="0.resinio.pool.ntp.org"

# workaround for self-signed certs, waiting for https://github.com/balena-os/meta-balena/issues/1398
TMPCRT=$(mktemp)
echo "${BALENA_ROOT_CA}" | base64 -d > "${TMPCRT}"

low_mem_threshold=10 #%
low_disk_threshold=10 #%
wifi_threshold=40 #%, very handwavy
expansion_threshold=80 #%
slow_disk_write=1000 #ms

GOOD="true"
BAD="false"

mapfile -t USERVICES < <(${TIMEOUT_CMD} "${ENG}" ps --format "{{.Names}}" | awk '/(resin|balena)_supervisor/{next;}{print}' 2> /dev/null)

# Helper functions
function announce_version()
{
	jq -n --arg dv "${DIAGNOSE_VERSION}" '{"diagnose_version":$dv}'
}

function get_meminfo_field()
{
	awk '/^'"$1"':/{print $2}' /proc/meminfo
}

function log_status()
{
	# success (g) ${1}
	# function (f) ${2}
	# status (s) ${3}
	jq -cn --argjson g "${1}" --arg f "${2}" --arg s "${3}" '[{"name":$f,"success":$g,"status":$s}]'
}

function test_upstream_dns()
{
	# force dnsmasq to print statistics to journal to read them back
	systemctl kill -s USR1 dnsmasq
	for i in $(journalctl -u dnsmasq | awk 'match($0, /[12]?[0-9]?[0-9]\.[12]?[0-9]?[0-9]\.[12]?[0-9]?[0-9]\.[12]?[0-9]?[0-9]/) {print substr($0, RSTART, RLENGTH)}'| sort -u); do
		# shellcheck disable=SC2001
		for j in "${external_fqdn}" "$(echo "${API_ENDPOINT}" | sed -e 's@^https*://@@')"; do
			if ! nslookup "${j}" "${i}" > /dev/null 2>&1; then
				echo "${FUNCNAME[0]}: DNS lookup failed for ${j} via upstream: ${i}"
			fi
		done;
	done
}

function test_wifi()
{
	local wifi_active_interfaces
	wifi_active_interfaces=$(${TIMEOUT_CMD} nmcli --terse --fields DEVICE,TYPE,STATE device status | \
		awk -F: '/wifi:connected$/{print $1}')
	if [[ -n ${wifi_active_interfaces} ]]; then
		local -i wifi_strength
		wifi_strengths=$(${TIMEOUT_CMD} nmcli --terse --fields DEVICE,ACTIVE,SIGNAL device wifi list)
		for ifname in ${wifi_active_interfaces}; do
			wifi_strength=$(echo "${wifi_strengths}" | awk -F: '/^'"${ifname}"':yes:/{print $3}')
			if (( wifi_strength < wifi_threshold )) && (( wifi_strength > 0 )); then
				echo "${FUNCNAME[0]}: Configured wifi interface ${ifname} has a weak signal (<${wifi_threshold}%)"
			fi
		done
	fi
}

function test_ping()
{
	local -i lost_packets
	lost_packets=$(${TIMEOUT_CMD} ping -c 3 "${external_fqdn}" 2>/dev/null | awk -F, '/loss/{print $7}')
	if (( lost_packets > 0 )); then
		echo "${FUNCNAME[0]}: Packets lost while pinging ${external_fqdn}"
	fi
}

function test_dockerhub()
{
	local -i balena_results
	balena_results=$(${TIMEOUT_CMD} ${ENG} search balena --limit 10 2>/dev/null | awk '/balena/' | wc -l)
	if (( balena_results != 10 )); then
		echo "${FUNCNAME[0]}: Could not query Docker Hub"
	fi
}

function test_balena_api()
{
	# can we reach the API?
	local api_ret
	local -i api_retval
	api_ret=$(CURL_CA_BUNDLE=${TMPCRT} ${TIMEOUT_CMD} curl -qs "${API_ENDPOINT}/ping")
	api_retval=$?
	if [[ "${api_ret}" != "OK" ]]; then
		# from man curl:
		# EXIT CODES
		# 60     Peer certificate cannot be authenticated with known CA certificates.
		if [ "${api_retval}" -eq 60 ]; then
			echo "${FUNCNAME[0]}: There may be a firewall blocking traffic to ${API_ENDPOINT} (SSL errors)"
			return
		fi
		echo "${FUNCNAME[0]}: Could not contact ${API_ENDPOINT}"
	fi
}

function test_balena_registry()
{
	# can we authenticate with the registry? TODO: this isn't really a good check for auth, just for connectivity
	# TODO: old OSes fail because no --password-stdin, so can't use that.
	if ! ${TIMEOUT_CMD} ${ENG} login "${REGISTRY_ENDPOINT}" -u "d_${UUID}" \
		--password "${DEVICE_API_KEY}" > /dev/null 2>&1; then
		echo "${FUNCNAME[0]}: Could not communicate with ${REGISTRY_ENDPOINT} for authentication"
	fi
	${TIMEOUT_CMD} ${ENG} logout "${REGISTRY_ENDPOINT}" > /dev/null
}

function test_write_latency()
{
	# from https://www.kernel.org/doc/Documentation/iostats.txt:
	#
	# Field  5 -- # of writes completed
	#	  This is the total number of writes completed successfully.
	# Field  8 -- # of milliseconds spent writing
	#	  This is the total number of milliseconds spent by all writes (as
	#	  measured from __make_request() to end_that_request_last()).
	local write_output
	write_output=$(awk -v limit=${slow_disk_write} '!/(loop|ram)/{if ($11/(($8>0)?$8:1)>limit){print $3": " $11/(($8>0)?$8:1) "ms / write, sample size " $8}}' /proc/diskstats)
	if [ -n "${write_output}" ]; then
		echo "${FUNCNAME[0]}" "Slow disk writes detected: ${write_output}"
	fi
}

function test_diskspace()
{
	# Last +0 forces the field to a number, stripping the '%' on the end.
	# Tested working on busybox.
	local -i used_percent
	local -i free_percent
	used_percent=$(df ${mountpoint} | tail -n 1 | awk '{print $5+0}')
	free_percent=$(( 100 - used_percent ))

	if (( free_percent < low_disk_threshold )); then
		echo "${FUNCNAME[0]}" "Low disk space: (df reports ${free_percent}% free)"
	fi
}

function test_disk_expansion()
{
	local -i expansion_perc
	# TODO: ceil is better, but floor is supported back to jq-1.5
	expansion_perc=$(lsblk -Jb -o NAME,SIZE,RM | jq -S '.blockdevices[] | select(has("children")) | select(.rm == "0").size as $total |
		[.children[].size | tonumber] | 100 * add / ($total | tonumber) | floor')
	if (( expansion_perc < expansion_threshold )) ; then
		echo "${FUNCNAME[0]}" "Block media device may not have fully expanded (${expansion_perc}% of available space)"
	fi
}

function is_valid_check()
{
	local list_type="${1}"
	shift
	local found=1
	read -r -a args <<< "$@"
	for i in ${args[*]}
	do
		if [ "${i}" == "${SLUG}" ] ; then
			found=0
			break
		fi
	done
	if [[ "${list_type}" == "WHITELIST" ]]; then
		return "${found}"
	elif [[ "${list_type}" == "BLACKLIST" ]]; then
		return $(( 1 - found ))
	fi
}

function run_tests()
{
	local original_check
	local subject
	original_check=${1}
	subject=${original_check//check_/}
	shift;

	local tests=("$@")

	local output
	output=""
	local cmd_out
	for i in "${tests[@]}"; do
		cmd_out=$(${i})
		if [ -n "${cmd_out}" ]; then
			output+=$'\n'$(printf '%s' "${cmd_out}")
		fi
	done
	if [ "$(echo "${output}" | wc -l)" -gt 1 ]; then
		log_status "${BAD}" "${original_check}" "Some ${subject} issues detected: ${output}"
	else
		log_status "${GOOD}" "${original_check}" "No ${subject} issues detected"
	fi
}

# Check functions
function check_networking()
{
	local tests=(
		test_upstream_dns
		test_wifi
		test_ping
		test_balena_api
		test_dockerhub
		test_balena_registry
	)
	run_tests "${FUNCNAME[0]}" "${tests[@]}"
}

function check_localdisk()
{
	local tests=(
		test_write_latency
		test_diskspace
		test_disk_expansion
	)
	run_tests "${FUNCNAME[0]}" "${tests[@]}"
}

function check_under_voltage(){
	local SLUG_WHITELIST=('raspberrypi3-64' 'raspberrypi4-64' 'raspberry-pi' 'raspberry-pi2' 'raspberrypi3' 'fincm3')
	if is_valid_check WHITELIST "${SLUG_WHITELIST[*]}"; then
		if dmesg | grep -q "Under-voltage detected\!"; then
			log_status "${BAD}" "${FUNCNAME[0]}" "Under-voltage events detected, check/change the power supply ASAP"
		else
			log_status "${GOOD}" "${FUNCNAME[0]}" "No under-voltage events detected"
		fi
	fi
}

function check_temperature(){
	# see https://github.com/balena-io/device-diagnostics/issues/168
	local SLUG_BLACKLIST=('jetson-nano' 'jn30b-nano')
	if is_valid_check BLACKLIST "${SLUG_BLACKLIST[*]}"; then
		local -i temp
		local -i therm_count=0
		for i in /sys/class/thermal/thermal* ; do
			if [ -e "$i/temp" ]; then
				therm_count+=1
				temp=$(cat "$i/temp")
				if (( temp >= 80000 )); then
					log_status "${BAD}" "${FUNCNAME[0]}" "Temperature above 80C detected ($i)"
					return
				fi
			fi
		done
		if (( therm_count > 0 )); then
			log_status "${GOOD}" "${FUNCNAME[0]}" "No abnormal temperature detected"
		fi
	fi
}

function check_balenaOS()
{
	# test resinOS 1.x based on matches like the following:
	# VERSION="1.24.0"
	# PRETTY_NAME="Resin OS 1.24.0"
	if grep -q -e '^VERSION="1.*$' -e '^PRETTY_NAME="Resin OS 1.*$' /etc/os-release; then
		log_status "${BAD}" "${FUNCNAME[0]}" "ResinOS 1.x is now completely deprecated"
	else
		if [[ "${DEVICE_TYPE}" != "${SLUG}" ]]; then
			log_status "${BAD}" "${FUNCNAME[0]}" "Custom balenaOS 2.x detected (custom device type)"
			return
		fi
		local versions
		versions=$(curl -qs --max-time 5 --retry 3 --retry-connrefused "${API_ENDPOINT}/device-types/v1/${SLUG}/images")
		if ! echo "${versions}" | jq -e --arg v "${VERSION}.${VARIANT_ID}" '.versions | index($v)' > /dev/null; then
			local latest
			latest=$(echo "${versions}" | jq -r '.latest' | sed -e 's/\.prod$//;s/\.dev$//')
			log_status "${BAD}" "${FUNCNAME[0]}" "balenaOS 2.x detected, but this version is not currently available in ${API_ENDPOINT} (latest version is ${latest})"
		else
			log_status "${GOOD}" "${FUNCNAME[0]}" "Supported balenaOS 2.x detected"
		fi
	fi
}

function check_memory()
{
	local -i total_kb
	local -i avail_kb
	local avail_exists

	total_kb=$(get_meminfo_field MemTotal)
	avail_exists=$(get_meminfo_field MemAvailable)

	if [ -z "${avail_exists}" ]; then
		# For kernels that don't support MemAvailable.
		# Not as accurate, but a good approximation.
		avail_kb=$(( $(get_meminfo_field MemFree) + \
			$(get_meminfo_field Cached) + \
			$(get_meminfo_field Buffers) ))
	else
		avail_kb="${avail_exists}"
	fi

	local -i percent_avail
	percent_avail=$(( 100 * avail_kb / total_kb ))

	if (( percent_avail < low_mem_threshold )); then
		local -i total_mb
		local -i avail_mb
		total_mb=$(( total_kb / 1024 ))
		avail_mb=$(( avail_kb / 1024 ))
		local -i used_mb
		used_mb=$(( total_mb - avail_mb ))
		log_status "${BAD}" "${FUNCNAME[0]}" "Low memory: ${percent_avail}% (${avail_mb}MB) available, ${used_mb}MB/${total_mb}MB used"
	else
		log_status "${GOOD}" "${FUNCNAME[0]}" "${percent_avail}% memory available"
	fi
}

function check_timesync()
{
	local is_time_synced
	is_time_synced=$(timedatectl | awk -F": " '/(System clock|NTP) synchronized:/{print $2}')
	if [[ "${is_time_synced}" != "yes" ]]; then
		log_status "${BAD}" "${FUNCNAME[0]}" "Time is not being synchronized via NTP"
	else
		log_status "${GOOD}" "${FUNCNAME[0]}" "Time is synchronized"
	fi
}

function check_container_engine()
{
	if (! systemctl is-active ${ENG} > /dev/null); then
		log_status "${BAD}" "${FUNCNAME[0]}" "Container engine ${ENG} is NOT running"
	else
		local -i engine_restarts
		engine_restarts=$(systemctl show -p NRestarts ${ENG} | awk -F= '{print $2}')
		if (( engine_restarts > 0 )); then
			local start_timestamp
			start_timestamp=$(systemctl show -p ExecMainStartTimestamp ${ENG} | awk -F= '{print $2}')
			log_status "${BAD}" "${FUNCNAME[0]}" "Container engine ${ENG} is up, but has ${engine_restarts} \
unclean restarts and may be crashlooping (most recent start time: ${start_timestamp})"
		else
			log_status "${GOOD}" "${FUNCNAME[0]}" "Container engine ${ENG} is running and has not restarted uncleanly"
		fi
	fi
}

function check_supervisor()
{
	# TODO: grab healthcheck results here
	local supervisor_version release_status api_version
	local -i versions
	supervisor_version=$(${TIMEOUT_CMD} ${ENG} ps -a --filter="name=(resin|balena).*supervisor" --format "{{.Image}}" | awk -F: '{print $2}')

	versions=$(curl -qs --max-time 5 --retry 3 --retry-connrefused \
		"${API_ENDPOINT}/v5/supervisor_release?\$filter=device_type%20eq%20'${DEVICE_TYPE}'%20and%20supervisor_version%20eq%20'${supervisor_version}'" | jq '. | length')
	api_version=$(curl -qs --max-time 5 --retry 3 --retry-connrefused \
		"${API_ENDPOINT}/v5/device?\$filter=uuid%20eq%20'${UUID}'" -H "Authorization: Bearer ${DEVICE_API_KEY}" | jq -r '[.d[0].supervisor_version] | "v\(.[0])"')
	if (( versions == 0 )); then
		release_status=" (unreleased Supervisor detected!)"
	fi
	if [[ "${api_version}" != "${supervisor_version}" ]]; then
		release_status+=" (unmatched local and remote Supervisor versions)"
	fi
	if ! (${TIMEOUT_CMD} ${ENG} ps | grep -q resin_supervisor) 2> /dev/null; then
		log_status "${BAD}" "${FUNCNAME[0]}" "Supervisor is NOT running${release_status}"
	else
		if ! curl -qs --max-time 10 "localhost:${LISTEN_PORT}/v1/healthy" > /dev/null; then
			log_status "${BAD}" "${FUNCNAME[0]}" "Supervisor is running, but may be unhealthy${release_status}"
		else
			log_status "${GOOD}" "${FUNCNAME[0]}" "Supervisor is running & healthy${release_status}"
		fi
	fi
}

function check_os_rollback()
{
	local health_path="/mnt/state/rollback-health-triggered"
	local altboot_path="/mnt/state/rollback-altboot-triggered"
	local rollback_detected=()
	declare -a HEALTHCHECK_FILES=("${health_path}" "${altboot_path}")
	for i in "${HEALTHCHECK_FILES[@]}"; do
		if [ -f "${i}" ]; then
			rollback_detected+=("${i}")
		fi
	done

	if (( ${#rollback_detected[@]} > 0 )); then
	    log_status "${BAD}" "${FUNCNAME[0]}" "OS rollbacks detected (file(s): ${rollback_detected[*]})"
	else
	    log_status "${GOOD}" "${FUNCNAME[0]}" "No OS rollbacks detected"
	fi
}

function check_service_restarts()
{
	local restarting=()
	local timed_out=()
	local -i restarting_count=0
	local -i service_count=0

	if (( ${#USERVICES[@]} > 0 )); then
		for service in "${USERVICES[@]}"; do
			if ! servicename_count=$(${TIMEOUT_CMD} ${ENG} inspect "${service}" -f '{{.Name}} {{.RestartCount}}'); then
				timed_out+=("${service}")
			else
				service_count+=1
				if [[ "$(echo "${servicename_count}" | awk '{print $2}')" -ne 0 ]]; then
					label="$(echo "${servicename_count}" | awk '{print "(service: "$1" restart count: "$2")"}')"
					restarting+=("${label}")
					restarting_count+=1
				fi
			fi
		done
	fi
	if (( restarting_count != 0 )); then
		log_status "${BAD}" "${FUNCNAME[0]}" "Some services are restarting unexpectedly: ${restarting[*]}"
	elif (( "${service_count}" < "${#USERVICES[@]}" )); then
		log_status "${BAD}" "${FUNCNAME[0]}" "Inspecting service(s) (${timed_out[*]}) has timed out, check data incomplete"
	else
		log_status "${GOOD}" "${FUNCNAME[0]}" "No services are restarting unexpectedly"
	fi
}

function check_image_corruption()
{
	local images output result="${GOOD}"
	local corrupted=()
	local timeout=()
	local -i corrupted_count
	local -i timeout_count
	# TODO: this command is filtering out any images with a size <1Kb (for delta-based images)
	images=$(${TIMEOUT_CMD} ${ENG} image ls --format "{{.ID}} {{.Size}}" | awk '/[0-9]+B/{next;}{print $1}' | sort -u)

	if (( ${#images[@]} > 0 )); then
		for i in ${images};
		do
			# TODO: the timeout here is probably too short to be effective in most cases, but let's gather
			# data and change if necessary
			if ! ${TIMEOUT_CMD} ${ENG} save "${i}" > /dev/null ; then
				# this retval indicates a timeout
				if (( $? = 124 )); then
					timeout_count+=1
					timeout+=("${i}")
				else
					corrupted_count+=1
					corrupted+=("${i}")
				fi
			fi
		done
		if (( corrupted_count != 0 )); then
			output+="Some images may be corrupted: ${corrupted[*]}\n"
			result="${BAD}"
		fi
		if (( timeout_count != 0 )); then
			output+="Saving images timed out, check data incomplete: ${timeout[*]}\n"
			result="${BAD}"
		fi
		if [ -z "${output}" ]; then
			output="No signs of ${ENG} image corruption"
		fi
		log_status "${result}" "${FUNCNAME[0]}" "${output}"
	fi
}

function check_user_services()
{
	# TODO: might as well track restarts here as well (convert to aggregated check)
	local checks_return="[]"
	local out healthcheck_output inspect
	if (( ${#USERVICES[@]} > 0 )); then
		for service in "${USERVICES[@]}"; do
			inspect=$(${TIMEOUT_CMD} "${ENG}" inspect "${service}")
			healthcheck_output=$(echo "${inspect}" | jq -r '.[].State.Health')
			if [[ -n "${healthcheck_output}" ]]; then
				# artificially limited to 100 chars
				# TODO: could probably be cleaned up
				# TODO: if a service is failing, see how many times in a row (.FailingStreak)
				out=$(echo "${healthcheck_output}" | jq -r '.Log[-1]|[.ExitCode,.Output[:100]]|"exit code: \(.[0]), output: \(.[1])"' | sed "s/\"/\'/g")
				success=$(echo "${healthcheck_output}" | jq -r '.Status == "healthy"')
				pretty_name=$(echo "${inspect}" | jq -r '.[].Config.Labels."io.balena.service-name"')
				checks_return=$(echo "[{\"name\": \"service_${pretty_name}\", \"status\":\"${out}\",\"success\": ${success}}]" "${checks_return}" | jq -s 'add')
			fi
		done
	fi
	echo "${checks_return}"
}

function run_checks()
{
	# TODO remove echo | jq
	echo "$(check_balenaOS)" \
	"$(check_under_voltage)" \
	"$(check_memory)" \
	"$(check_temperature)" \
	"$(check_container_engine)" \
	"$(check_supervisor)" \
	"$(check_networking)" \
	"$(check_localdisk)" \
	"$(check_service_restarts)" \
	"$(check_timesync)" \
	"$(check_os_rollback)" \
	"$(check_image_corruption)" \
	"$(check_user_services)" \
	| jq -s 'add | {checks:.}'
}

jq --argjson a1 "$(announce_version)" --argjson a2 "$(run_checks)" -cn '$a1 + $a2'
rm -f "${TMPCRT}" > /dev/null 2>&1
