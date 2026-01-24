#!/usr/bin/env bash

set -euo pipefail

IPFS_FILE=".ipfs.yml"

if [[ ! -f "$IPFS_FILE" ]]; then
	printf "Error: '%s' not found.\n" "$IPFS_FILE" >&2
	exit 1
fi

printf "Reading %s...\n" "$IPFS_FILE"

# Extract and validate version
version=$(awk '/^version:[[:space:]]*/ {print $2; exit}' "$IPFS_FILE" || echo "unknown")

if [[ "$version" == "unknown" ]]; then
	printf "Error: No 'version:' field found in %s\n" "$IPFS_FILE" >&2
	exit 1
fi

if [[ "$version" != "1" ]]; then
	printf "Error: Unsupported version '%s' (only version 1 is supported)\n" "$version" >&2
	exit 1
fi

printf "Detected version: %s (supported)\n\n" "$version"

# Parse filename → cid pairs (version 1 structure)
awk '
	$1 ~ /^[a-zA-Z0-9._-]+:$/ {
		gsub(/:$/, "", $1)
		file = $1
		getline
		if ($1 == "cid:") {
			print file " " $2
		}
	}
' "$IPFS_FILE" | while read -r file cid; do
	printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
	printf "File: %s\n" "$file"
	printf " CID: %s\n" "$cid"

	if [[ -e "$file" ]]; then
		printf "  → Already exists → skipping\n\n"
		continue
	fi

	printf "  → Starting download...\n\n"

	if ipget "$cid" -o "$file" --progress; then
		printf "\n  → Success\n"
		if [[ -f "$file" ]]; then
			size=$(du -h "$file" | cut -f1)
			printf "  → Saved: %s (%s)\n" "$file" "$size"
		fi
	else
		printf "\n  → Download failed\n" >&2
		# Clean up partial download (recommended to avoid leaving broken files)
		if [[ -f "$file" ]]; then
			rm -f "$file"
			printf "  → Removed incomplete file\n"
		fi
	fi

	printf "\n"
done

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Finished processing all entries.\n"
