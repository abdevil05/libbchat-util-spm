#!/bin/bash

set -e

mute=">/dev/null 2>&1"
if [[ "$1" == "-v" ]]; then
	mute=
fi

cwd="$(dirname "${BASH_SOURCE[0]}")"
workdir="$(mktemp -d)"
mkdir -p "${workdir}/Logs"
repo_dir="$(cd "${cwd}/" && pwd)"
source_dir="${workdir}/libBchat-source"
build_dir="build-ios"
zip_path="${source_dir}/${build_dir}/libbchat-util.xcframework.zip"
beldex_url="${BELDEX_URL:-http://209.126.86.103:8080/Beldex-Projects/Bchat/ios/libbchat-util}"
progress_file="${workdir}/progress.tmp"
should_clean_up=1
should_build_from_source=0

print_usage_and_exit() {
	cat <<- EOF
	Usage:
	  $ $(basename "$0") [-b] [-k] [-v] [-h] [<libBchat_tag>]

	Options:
	 -h      Show this message
	 -v      Verbose output
	 -k      Keep the temporary directory
	 -b      Build from source rather than fetching from beldex
	EOF

	rm -rf "$workdir"
	exit 1
}

read_command_line_arguments() {
	while getopts 'hvkb' OPTION; do
		case "${OPTION}" in
			h)
				print_usage_and_exit
				;;
			v)
				mute=
				;;
			k)
				should_clean_up=0
				;;
			b)
				should_build_from_source=1
				;;
			*)
				;;
		esac
	done

	shift $((OPTIND-1))

	if [[ "$should_clean_up" == "1" ]]; then
		trap 'rm -rf "$workdir"' EXIT
	fi
	trap cleanup INT TERM

	libBchat_tag="$1"
	if [[ -z "$libBchat_tag" ]]; then
		echo "❌ Please specify the release tag."
		exit 1
	fi
}

cleanup() {
  echo ""

  # Force kill the spinner and any child processes (like tail)
  if [ -f "${workdir}/spinner.pid" ]; then
    spinner_pid=$(cat "${workdir}/spinner.pid")
    # Get the process group id of the spinner process.
    pgid=$(ps -o pgid= -p "$spinner_pid" | tr -d ' ')
    if [ -n "$pgid" ]; then
      # Kill the entire group (note the negative sign)
      kill -TERM -"$pgid" 2>/dev/null
    else
      # Fallback: kill the spinner process directly
      kill -TERM "$spinner_pid" 2>/dev/null
    fi
  fi

  # Add the 'spinner.stop' as a backup mechanism
  touch "${workdir}/spinner.stop"
  sleep 0.3

  stop_spinner "Process cancelled" "fail"

  exit 1
}

start_spinner() {
  local message="$1"
  local logfile="$2"
  
  # If a logfile is provided, clear any previous progress.
  if [ -n "$logfile" ]; then
  	> "${progress_file}"
  else
  	rm -f "${progress_file}"
  fi

  echo -n "$message "
  
  # Define spinner characters
  spinner='-\|/'

  # Create a named pipe for communication
  local pipe="${workdir}/spinner.pipe"
  rm -f "$pipe"
  mkfifo "$pipe"

  (
  	trap 'exit 0' SIGTERM SIGINT

    # If a logfile is specified, tail it to extract percentage progress
    if [ -n "$logfile" ]; then
      tail -n0 -F "$logfile" 2>/dev/null | while read -r line; do
      	# Skip empty lines
    	[ -z "$line" ] && continue

      	if [ -f "${workdir}/spinner.stop" ]; then
		  break
		fi

        if [[ "$line" =~ ^[[:space:]]*([0-9]+)\.?[0-9]*% ]]; then
          printf "%s" "${BASH_REMATCH[1]}" > "$progress_file"
		fi
      done &
      local tail_pid=$!

      # Make sure to kill tail when this process exits
      trap "kill $tail_pid 2>/dev/null; exit 0" SIGTERM SIGINT EXIT
    fi

    i=0
    # Spinner loop: update the display every 0.2 seconds
    while :; do
      local percent=""
      if [ -n "$logfile" ]; then
        percent=$(cat "$progress_file" 2>/dev/null)
      fi
      # Format the percentage to always occupy 4 characters.
      local disp_percent
      if [ -n "$percent" ]; then
        disp_percent=$(printf "%3d%%" "$percent")
      else
        disp_percent="    "
      fi

      i=$(( (i+1) % ${#spinner} ))
      if [ -n "$logfile" ]; then
        # Display spinner with percentage.
        printf "\r\033[K%s %s %s" "$message" "$disp_percent" "${spinner:$i:1}"
      else
        # Display spinner without percentage.
        printf "\r\033[K%s %s" "$message" "${spinner:$i:1}"
      fi

      sleep 0.2

      if [ -f "${workdir}/spinner.stop" ]; then
	    break
	  fi
    done

    # Clean up pipe
    rm -f "$pipe"
  ) &

  # Save the spinner's PID so we can kill it later
  spinner_pid=$!
  echo $spinner_pid > "${workdir}/spinner.pid"
}

stop_spinner() {
  local message="$1"
  local status="$2"  # Expect "success", "warn" or "fail"

  if [ -f "${workdir}/spinner.pid" ]; then
  	kill $(cat "${workdir}/spinner.pid") 2>/dev/null || true
  	rm -f "${workdir}/spinner.pid" || true
  fi

  # Choose an icon based on the status.
  local icon
  if [ "$status" = "success" ]; then
    icon="✅"
  elif [ "$status" = "warn" ]; then
  	icon="⚠️"
  else
    icon="❌"
  fi

  local final_percent="    "
  if [ -f "$progress_file" ]; then
    local last_val
    read -r last_val < "$progress_file" 2>/dev/null || true
    if [ -n "$last_val" ]; then
      final_percent=$(printf "%3d%%" "$last_val")
    fi
    rm -f "$progress_file" || true
  	printf "\r\033[K%s %s %s\n" "$message" "$final_percent" "$icon"
  else
  	echo -e "\r\033[K$message $icon"
  fi

  # Always return success
  return 0
}

check_url() {
  local url="$1"
  local output_file="$2"
  local timeout=10
  
  # Use curl with timeout
  if curl -s --connect-timeout $timeout --max-time $timeout -o "$output_file" "$url"; then
    return 0
  else
    return 1
  fi
}

get_file_size() {
	local file_path="$1"

	if stat -f%z "$file_path" >/dev/null 2>&1; then
		stat -f%z "$file_path"
	else
		stat -c%s "$file_path"
	fi
}

retrieve_ci_build_for_tag() {
	local file_name="libbchat-util-ios-${libBchat_tag}"
	local file_pattern="${file_name}.tar.xz"
	local download_url=""

	# Create the download dir
	mkdir -p "${workdir}/Downloads"

	# First check in tag directory
	local tag_output="${workdir}/Downloads/tag_output.html"
	start_spinner "Checking ${libBchat_tag} build on beldex"

	if check_url "${beldex_url}/${libBchat_tag}/" "${tag_output}"; then
		if grep -q "$file_pattern" "${tag_output}"; then
			download_url="${beldex_url}/${libBchat_tag}/${file_pattern}"
			stop_spinner "Checking ${libBchat_tag} build on beldex" "success"
		fi
	fi

	# If we didn't get a download url from the tag directory then fallback to stable
	if [ -z "$download_url" ]; then
		local stable_output="${workdir}/Downloads/stable_output.html"
		start_spinner "Checking for stable ${libBchat_tag} build on beldex"

		if check_url "${beldex_url}/stable/" "${stable_output}"; then
			if grep -q "$file_pattern" "${stable_output}"; then
				download_url="${beldex_url}/stable/${file_pattern}"
				stop_spinner "Checking for stable ${libBchat_tag} build on beldex" "success"
			fi
		fi
	fi

	# If we didn't get a download url from the stable directory then fallback to dev
	if [ -z "$download_url" ]; then
		stop_spinner "Checking for stable ${libBchat_tag} build on beldex" "warn"

		local dev_output="${workdir}/Downloads/dev_output.html"
		start_spinner "Checking for dev ${libBchat_tag} build on beldex"

		if check_url "${beldex_url}/dev/" "${dev_output}"; then
			if grep -q "$file_pattern" "$dev_output"; then
				download_url="${beldex_url}/dev/${file_pattern}"
				stop_spinner "Checking for dev ${libBchat_tag} build on beldex" "success"
			fi
		fi
	fi

	if [ -z "$download_url" ]; then
		stop_spinner "Checking for dev ${libBchat_tag} build on beldex" "fail"
		echo "Unable to find CI build for ${libBchat_tag}."
		exit 1
	fi

	start_spinner "Downloading ${libBchat_tag} from $download_url" "${workdir}/Downloads/curl.progress"

	printf "0" > "$progress_file"
	download_file="${workdir}/Downloads/${file_pattern}"
	expected_size=$(curl -sI "$download_url" | awk '/[Cc]ontent-[Ll]ength/ {print $2}' | tr -d '\r')
	curl -f -L --max-time 300 -o "$download_file" "$download_url" > /dev/null 2>&1 &
	curl_pid=$!

	while kill -0 "$curl_pid" 2>/dev/null; do
		if [ -f "$download_file" ] && [ -n "$expected_size" ]; then
			current_size=$(get_file_size "$download_file")
			percent=$(( current_size * 100 / expected_size ))
			if [ "$percent" -gt 100 ]; then percent=100; fi
			printf "%s" "$percent" > "$progress_file"
		fi
		sleep 0.2
	done

	wait "$curl_pid"
	curl_status=$?

	if [ "$curl_status" -eq 0 ]; then
		printf "100" > "$progress_file"
		stop_spinner "Downloading ${libBchat_tag} from $download_url" "success"
	else
		stop_spinner "Downloading ${libBchat_tag} from $download_url" "fail"
		echo "Unable to download ${libBchat_tag} from ${download_url}."
		exit 1
	fi

	start_spinner "Extracting ${libBchat_tag} tar.xz"

	if ! tar -xf "${download_file}" -C "${workdir}/Downloads"; then
		stop_spinner "Extracting ${libBchat_tag} tar.xz" "fail"
		echo "Failed to extract tar.xz."
		exit 1
	fi

	stop_spinner "Extracting ${libBchat_tag} tar.xz" "success"

	start_spinner "Compressing XCFramework"
	mkdir -p "$(dirname "$zip_path")"
	rm -rf "${zip_path}"
	if ditto -c -k --keepParent "${workdir}/Downloads/${file_name}/libbchat-util.xcframework" "${zip_path}" 2>&1; then
		stop_spinner "Compressing XCFramework" "success"
	else
		stop_spinner "Compressing XCFramework" "fail"
		echo "Failed to compress XCFramework."
		exit 1
	fi
}

retrieve_license_for_tag() {
	start_spinner "Retrieving latest libBchat LICENSE"
	local license_url="https://raw.githubusercontent.com/peter-pratt/libbchat-util/refs/tags/${libBchat_tag}/LICENSE"
	local license_output="${workdir}/Downloads/LICENSE"

	if check_url "${license_url}" "${license_output}"; then
		stop_spinner "Retrieving latest libBchat LICENSE" "success"
    else
    	stop_spinner "Retrieving latest libBchat LICENSE" "fail"
    	exit 1
    fi

    rm -rf "${repo_dir}/LICENSE"
    mv "${license_output}" "${repo_dir}/LICENSE"
}

clone_source() {
	if ! [[ -d "$source_dir" ]]; then
		rm -rf "$source_dir"
	fi

	start_spinner "Cloning libBchat"
	eval git clone https://github.com/peter-pratt/libbchat-util.git "$source_dir" "$mute"
	stop_spinner "Cloning libBchat" "success"

	start_spinner "Checking out libBchat latest tag: $libBchat_tag"
	cd "${source_dir}"
	eval git checkout -f "${libBchat_tag}" "$mute"
	stop_spinner "Checking out libBchat latest tag: $libBchat_tag" "success"
}

build_arch() {
	local platform=$1
	local arch=$2
	local log_file=$3
	local build_log_file="${workdir}/Logs/${log_file}"

	start_spinner "Building libBchat for ${platform} ${arch}" "${build_log_file}"
	if TARGET_BUILD_DIR="${build_dir}" TARGET_TEMP_DIR="${build_dir}" PLATFORM_NAME="$platform" ARCHS="$arch" "${source_dir}/utils/ios.sh" "libbchat-util" true false false false >"${build_log_file}" 2>&1; then
    	stop_spinner "Building libBchat for ${platform} ${arch}" "success"
	else
		stop_spinner "Building libBchat for ${platform} ${arch}" "fail"
		mkdir -p "${repo_dir}/build/logs" && cp "${build_log_file}" "${repo_dir}/build/logs/${log_file}"
		echo "Failed to build for ${platform} ${arch}. See log file at ${repo_dir}/build/logs/${log_file} for more info."
		exit 1
	fi
}

build_xcframework() {
	cd "${source_dir}"

	# Individually build the different architectures we want to include
	build_arch "iphonesimulator" "arm64" "libbchat-util-build-sim-arm64.log"
	build_arch "iphonesimulator" "x86_64" "libbchat-util-build-sim-x86_64.log"
	build_arch "iphoneos" "arm64" "libbchat-util-build-device-arm64.log"

	# Then merge them into multi-architecture static libraries (as needed)
	local merge_log_file="${workdir}/Logs/libbchat-util-merge.log"
	start_spinner "Merging libBchat architectures"
	if TARGET_BUILD_DIR="${build_dir}" TARGET_TEMP_DIR="${build_dir}" ARCHS="arm64 x86_64" "${source_dir}/utils/ios.sh" "libbchat-util" false true false false >"$merge_log_file" 2>&1; then
    	stop_spinner "Merging libBchat architectures" "success"
	else
		stop_spinner "Merging libBchat architectures" "fail"
		mkdir -p "${repo_dir}/build/logs" && cp "${merge_log_file}" "${repo_dir}/build/logs/libbchat-util-merge.log"
		echo "Failed to merge architectures. See log file at ${repo_dir}/build/logs/libbchat-util-merge.log for more info."
		exit 1
	fi

	# Create the XCFramework
	local framework_log_file="${workdir}/Logs/libbchat-util-framework.log"
	start_spinner "Creating libBchat XCFramework"
    if TARGET_BUILD_DIR="${build_dir}" TARGET_TEMP_DIR="${build_dir}" ARCHS="arm64 x86_64" "${source_dir}/utils/ios.sh" "libbchat-util" false false true false >"$framework_log_file" 2>&1; then
    	stop_spinner "Creating libBchat XCFramework" "success"
	else
		stop_spinner "Creating libBchat XCFramework" "fail"
		mkdir -p "${repo_dir}/build/logs" && cp "${framework_log_file}" "${repo_dir}/build/logs/libbchat-util-framework.log"
		echo "Failed to create XCFramework. See log file at ${repo_dir}/build/logs/libbchat-util-framework.log for more info."
		exit 1
	fi

	# And finally archive the XCFramework
	start_spinner "Compressing XCFramework"
	mkdir -p "$(dirname "$zip_path")"
	rm -rf "${zip_path}"
	if ditto -c -k --keepParent "${build_dir}/libbchat-util.xcframework" "${zip_path}" 2>&1; then
		stop_spinner "Compressing XCFramework" "success"
	else
		stop_spinner "Compressing XCFramework" "fail"
		echo "Failed to compress XCFramework."
		exit 1
	fi
}

update_license() {
	rm -rf "${repo_dir}/LICENSE"
	cp "${source_dir}/LICENSE" "${repo_dir}/LICENSE"
}

update_readme() {
	echo -n "Updating README.md..."
	current_version="$(grep '\* This Package' "${repo_dir}/README.md" | cut -d '*' -f 3)"

	export new_version="${libBchat_tag#v}" upstream_version="${libBchat_tag}"
	
	if [[ "${current_version}" == "${libBchat_tag#v}" ]] && \
		[[ -z "$force_release" ]]; then
		echo "LibBchat-Util (${libBchat_tag}) version did not change. Skipping release."
		exit 1
	fi

	envsubst < "${repo_dir}/assets/README.md.in" > "${repo_dir}/README.md"

	echo -e "\rUpdated README.md ✅"
}

update_swift_package() {
	echo -n "Updating Package.swift..."
	export checksum
	checksum=$(swift package compute-checksum "$zip_path")
	envsubst < "${repo_dir}/assets/Package.swift.in" > "${repo_dir}/Package.swift"
	echo -e "\rUpdated Package.swift ✅"
}

make_release() {
	echo "Making ${new_version} release... 🚢"

	local commit_message="libBchat Swift Package Manager ${new_version}"

	cd "${repo_dir}"
	git add "${repo_dir}/README.md" "${repo_dir}/Package.swift" "${repo_dir}/LICENSE"
	git commit -m "$commit_message"
	git tag -m "$commit_message" "${new_version}"

	mv "${zip_path}" "${repo_dir}/libbchat-util.xcframework.zip"

	echo "🎉 Release is ready to upload, archive at \"./libbchat-util.xcframework.zip\""
}

main() {
	read_command_line_arguments "$@"
	
	printf '%s\n' "Using directory at ${workdir}"

	if [[ "$should_clean_up" != "1" ]]; then
		printf '%s\n' "    Note: Directory will not automatically be cleaned up"
	fi

	if [[ "$should_build_from_source" != 1 ]]; then
		retrieve_ci_build_for_tag
		retrieve_license_for_tag
	else
		clone_source "$libBchat_tag"
		build_xcframework
		update_license
	fi

	update_readme
	update_swift_package
	make_release
	
	if [[ "$should_clean_up" == "1" ]]; then
		rm -rf "$workdir"
	fi

	return 0
}

main "$@"
