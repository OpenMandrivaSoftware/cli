#!/usr/bin/env bash

abf_file=".abf.yml"

if [ ! -f "${abf_file}" ]; then
	printf "'${abf_file}' doesn't exist, exiting.\n"
	exit 0
fi

printf "Parsing file '${abf_file}'...\n"

sed -rn '$G;s/^[\"'\''[:space:]]*([^[:space:]:\"'\'']+)[\"'\''[:space:]]*.*[\"'\''[:space:]]*([0-9a-fA-F]{40})[\"'\''[:space:]]*$/\1 \2/p' ${abf_file} | \

while read file sha; do
	printf "\nFound entry: file=${file} sha1sum=${sha}\n"

	if [ -e ${file} ]; then
		if printf "${sha}  ${file}" | sha1sum -c --status; then
			printf "File already exists, hash matching!\n"
		else
			printf "File already exists, hash not matching! Skipping...\n"
		fi
	else
		if wget -qO - "https://file-store.openmandriva.org/download/${sha}" > "${file}"; then
			printf "Download complete... "

			if printf "${sha}  ${file}" | sha1sum -c --status; then
				printf "hash matching!\n"
			else
				printf "hash not matching! Skipping...\n"
			fi
		else
			printf "Download failed! Skipping...\n"
		fi
	fi
done
