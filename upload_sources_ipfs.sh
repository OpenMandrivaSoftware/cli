#!/usr/bin/env bash

set -euo pipefail

# Configuration
CAR_BIN="${CAR_BIN:-car}"
PACK_CAR_SCRIPT="/usr/share/hos/car_pack.sh"
UPLOAD_CAR_SCRIPT="/usr/share/hos/car_upload.sh"
IPFS_YML=".ipfs.yml"

usage() {
	cat <<EOF
Usage: $0 <spec-file.spec>

Uploads new SourceN: entries from an RPM spec file as CARs (skips existing CIDs),
using rpmspec for full macro expansion, then updates .ipfs.yml.

Requires: rpmdevtools (rpmspec)

Arguments:
  <spec-file.spec>        Path to the RPM spec file

Examples:
  $0 package.spec
  $0 ~/rpmbuild/SPECS/kernel.spec
EOF
	exit 1
}

if [[ $# -ne 1 || ! -f "$1" ]]; then
	echo "Error: Please provide a valid .spec file"
	usage
fi

SPEC_FILE="$1"
SPEC_DIR=$(dirname "$SPEC_FILE")
IPFS_YML_PATH="$SPEC_DIR/$IPFS_YML"

echo "Processing spec: $SPEC_FILE"
echo "Working directory: $SPEC_DIR"
echo "Will update/create: $IPFS_YML_PATH"

# Check for rpmspec
if ! command -v rpmspec >/dev/null 2>&1; then
	err "rpmspec not found. Please install rpmdevtools (dnf install rpmdevtools)"
fi

# Load existing .ipfs.yml if present
declare -A EXISTING_CIDS=()
if [[ -f "$IPFS_YML_PATH" ]]; then
	echo "Loading existing CIDs from $IPFS_YML_PATH..."
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*([^:]+):[[:space:]]*$ ]]; then
			current_source="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ cid:[[:space:]]*(baf[0-9a-z]+) ]]; then
			EXISTING_CIDS["$current_source"]="${BASH_REMATCH[1]}"
		fi
	done < "$IPFS_YML_PATH"
	echo "Found ${#EXISTING_CIDS[@]} existing entries"
else
	echo "No existing $IPFS_YML — will create it"
fi

# Extract all expanded, non-commented SourceN: lines
SOURCES=$(rpmspec -P "$SPEC_FILE" 2>/dev/null | grep -E '^[[:space:]]*Source[0-9]+:' | grep -v '^[[:space:]]*#' || true)

if [[ -z "$SOURCES" ]]; then
	echo "No non-commented SourceN: lines found in spec (after macro expansion)."
	exit 0
fi

# Process each source
declare -A NEW_SOURCES_CIDS=()
while IFS= read -r line; do
	# Skip empty or invalid lines
	[[ -z "$line" ]] && continue

	if [[ "$line" =~ ^Source([0-9]+):[[:space:]]+(.+)$ ]]; then
		index="${BASH_REMATCH[1]}"
		source_path="${BASH_REMATCH[2]}"

		# Skip if already in .ipfs.yml
		if [[ -n "${EXISTING_CIDS[$source_path]:-}" ]]; then
			echo "Skipping $source_path — already has CID: ${EXISTING_CIDS[$source_path]}"
			continue
		fi

		full_path=$(realpath -m "$SPEC_DIR/$source_path" 2>/dev/null || echo "")
		if [[ -z "$full_path" || ! -e "$full_path" ]]; then
			echo "Warning: Source $source_path not found at $full_path — skipping"
			continue
		fi

		echo "Uploading new source: $source_path ($full_path)"

		# Create temp CAR file
		CAR_FILE=$(mktemp --suffix=.car 2>/dev/null || {
			echo "Warning: mktemp failed, using fallback"
			CAR_FILE="/tmp/upload-car-$(date +%s).car"
		})

		touch "$CAR_FILE" 2>/dev/null || {
			echo "Error: Cannot write to temp file $CAR_FILE (check /tmp permissions)"
			continue
		}

		# Pack CAR
		if ! "$PACK_CAR_SCRIPT" --force -o "$CAR_FILE" "$full_path"; then
			echo "Error packing $source_path"
			rm -f "$CAR_FILE" 2>/dev/null
			continue
		fi

		# Extract root CID locally (reliable!)
		ROOT_CID=$("$CAR_BIN" root "$CAR_FILE" 2>/dev/null || echo "")
		if [[ -z "$ROOT_CID" ]]; then
			echo "Error: Could not extract root CID from $CAR_FILE"
			rm -f "$CAR_FILE" 2>/dev/null
			continue
		fi

		# Upload live (progress visible), no extra capture/tee
		echo "Uploading to node for pinning..."
		set +e
		"$UPLOAD_CAR_SCRIPT" --force "$CAR_FILE" 2>&1
		UPLOAD_EXIT=$?
		set -e

		# Clean up CAR file
		rm -f "$CAR_FILE" 2>/dev/null

		if [[ $UPLOAD_EXIT -eq 0 ]]; then
			NEW_SOURCES_CIDS["$source_path"]="$ROOT_CID"
			echo "  → Pinned successfully, root CID: $ROOT_CID"
		else
			echo "  → Pinning failed (exit $UPLOAD_EXIT), but local CID is $ROOT_CID"
			echo "	You can still use the CID locally or retry pinning later"
		fi
	fi
done <<< "$SOURCES"

# If nothing new to upload
if [[ ${#NEW_SOURCES_CIDS[@]} -eq 0 ]]; then
	echo "No new sources to upload (all already in .ipfs.yml or failed)."
	exit 0
fi

# Update .ipfs.yml
echo "Updating $IPFS_YML_PATH with ${#NEW_SOURCES_CIDS[@]} new entries"

# Start with existing content or new file
if [[ -f "$IPFS_YML_PATH" ]]; then
	YAML_CONTENT=$(cat "$IPFS_YML_PATH")
else
	YAML_CONTENT="version: 1\nsources:"
fi

# Append new entries
for source in "${!NEW_SOURCES_CIDS[@]}"; do
	cid="${NEW_SOURCES_CIDS[$source]}"
	YAML_CONTENT+=$'\n'
	YAML_CONTENT+="  $source:\n"
	YAML_CONTENT+="	cid: $cid"
done

# Write back
echo -e "$YAML_CONTENT" > "$IPFS_YML_PATH"
echo "Done. Updated $IPFS_YML_PATH"

# Show final file
echo ""
echo "Current .ipfs.yml content:"
cat "$IPFS_YML_PATH"
