#!/usr/bin/env bash

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
				;;
			--arch=*)
				arch="${1#*=}"
				;;
			--opts=*)
				opts="${1#*=}"
				;;
		esac
		shift
	done

	printf "Target architecture: '%s'\n" "$arch"

	local spec
	for spec in *.spec; do
		local project=${spec%.*}
		printf "Project: '%s'\n" "$project"

		mkdir -p "${PWD}/BUILD"

		local logname="${project}_${action}_$(/bin/date +%Y%m%d_%H%M%S).log"

		run_in_bwrap rpmbuild "$action" \
			--target "$arch" \
			--define "_topdir ${PWD}" \
			--define "_sourcedir ${PWD}" \
			"$spec" $opts \
			2>&1 | tee "$logname"

		local status=${PIPESTATUS[0]}

		printf "Build log is saved to '%s'.\n" "$logname"

		if [ "$status" -ne 0 ]; then
			printf "Build failure!\n"
			break
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
