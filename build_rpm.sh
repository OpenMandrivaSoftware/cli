#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 [OPTIONS] [spec_file1.spec spec_file2.spec ...]

Builds RPM packages from .spec files using rpmbuild in a bwrap sandbox.

If no .spec files are provided, builds all *.spec files in the current directory.

Options:
  --action=VALUE        rpmbuild action (default: -bb)
                        Examples: -bb (build binary), -bs (source RPM), -bp (prep)
  --arch=VALUE          Target architecture (default: auto-detected)
  --opts=VALUE          Additional rpmbuild options (e.g. "--with debug")
  --help, -h            Show this help message

Examples:
  $0                          # Build all *.spec in current directory
  $0 package.spec             # Build only package.spec
  $0 car.spec vendor.spec     # Build multiple specific specs
  $0 --action=-bs car.spec    # Build source RPM only
  $0 --opts="--with debug"    # Pass custom rpmbuild flags
EOF
	exit 0
}

main() {
	local action="-bb"
	local arch
	arch="$(uname -m)"
	local opts=""

	if [ "$arch" = "x86_64" ]; then
		arch="$(detect_x86_64_level)"
	fi

	printf "Host architecture: '%s'\n" "$arch"

	# Parse arguments
	while [ $# -gt 0 ]; do
		case "$1" in
			--action=*)
				action="${1#*=}"
				shift
				;;
			--arch=*)
				arch="${1#*=}"
				shift
				;;
			--opts=*)
				opts="${1#*=}"
				shift
				;;
			--help|-h)
				usage
				;;
			*)
				break
				;;
		esac
	done

	printf "Target architecture: '%s'\n" "$arch"

	local specs=()

	if [ $# -gt 0 ]; then
		specs=("$@")
	else
		specs=(*.spec)
		if [ ${#specs[@]} -eq 0 ] || [ "${specs[0]}" = "*.spec" ]; then
			echo "Error: No .spec files found in current directory and no files specified."
			exit 1
		fi
	fi

	local status=0

	for spec in "${specs[@]}"; do
		if [ ! -f "$spec" ]; then
			echo "Warning: File not found, skipping: $spec"
			continue
		fi

		local project="${spec%.*}"
		printf "\nProject: '%s'\n" "$project"

		mkdir -p "${PWD}/BUILD"

		local logname="${project}_${action//-/}_$(date -u +"%Y-%m-%dT%H:%M:%SZ").log"

		echo "Running: rpmbuild $action --target $arch --define \"_topdir ${PWD}\" --define \"_sourcedir ${PWD}\" $spec $opts"
		echo "Log: $logname"

		run_in_bwrap rpmbuild "$action" \
			--target "$arch" \
			--define "_topdir ${PWD}" \
			--define "_sourcedir ${PWD}" \
			"$spec" $opts \
			2>&1 | tee "$logname"

		local cmd_status=${PIPESTATUS[0]}

		printf "Build log saved to '%s'.\n" "$logname"

		if [ "$cmd_status" -ne 0 ]; then
			printf "Build failure for %s!\n" "$project"
			status=1
			# break # Uncomment to stop on first error
		fi
	done

	exit "$status"
}

run_in_bwrap() {
	bwrap \
		--hostname builder \
		--unshare-net \
		--unshare-ipc \
		--unshare-pid \
		--unshare-uts \
		--bind "$PWD" "$PWD" \
		--ro-bind /bin /bin \
		--ro-bind /sbin /sbin \
		--ro-bind /usr /usr \
		--ro-bind /lib /lib \
		--ro-bind /lib64 /lib64 \
		--ro-bind /var/lib/rpm /var/lib/rpm \
		--dev /dev \
		--proc /proc \
		--tmpfs /tmp \
		--tmpfs /var/tmp \
		"$@"
}

detect_x86_64_level() {
	local flags
	flags=$(grep -m1 '^flags' /proc/cpuinfo)

	has() { grep -qw "$1" <<<"$flags"; }

	# v4
	if has avx512f && has avx512dq && has avx512cd && has avx512bw && has avx512vl; then
		echo x86_64_v4
		return
	fi

	# v3
	if has avx && has avx2 && has bmi1 && has bmi2 && has fma; then
		echo x86_64_v3
		return
	fi

	# v2
	if has sse3 && has ssse3 && has sse4_1 && has sse4_2 && has popcnt; then
		echo x86_64_v2
		return
	fi

	echo x86_64
}

main "$@"
