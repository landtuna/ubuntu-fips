#!/usr/bin/env bash
set -Eeuo pipefail

# Build the Ubuntu Noble FIPS image using the local Ubuntu Pro attach config.
# The attach config is passed to Buildah as a secret and is never copied into
# the image.

IMAGE_TAG="${IMAGE_TAG:-ubuntu-noble-fips}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERFILE="${CONTAINERFILE:-$SCRIPT_DIR/Containerfile.fips}"
CONTEXT_DIR="${CONTEXT_DIR:-$SCRIPT_DIR}"

usage() {
    cat <<EOF
Usage:
  bash $0 [attach-config]

Builds: $IMAGE_TAG
Containerfile: $CONTAINERFILE
Context: $CONTEXT_DIR
Attach config: ${PRO_ATTACH_CONFIG:-$SCRIPT_DIR/pro-attach-config.toml}

Overrides:
  IMAGE_TAG=registry.example/ubuntu-noble-fips bash $0
  PRO_ATTACH_CONFIG=/path/to/config.yaml bash $0
  CONTAINERFILE=/path/to/Containerfile bash $0
  CONTEXT_DIR=/path/to/context bash $0
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

ATTACH_CONFIG="${1:-${PRO_ATTACH_CONFIG:-$SCRIPT_DIR/pro-attach-config.toml}}"

if ! command -v buildah >/dev/null 2>&1; then
    echo "Required command not found: buildah" >&2
    exit 1
fi

if [[ ! -f "$CONTAINERFILE" ]]; then
    echo "Containerfile not found: $CONTAINERFILE" >&2
    exit 1
fi

if [[ ! -d "$CONTEXT_DIR" ]]; then
    echo "Build context directory not found: $CONTEXT_DIR" >&2
    exit 1
fi

if [[ ! -r "$ATTACH_CONFIG" ]]; then
    echo "Attach config is not readable: $ATTACH_CONFIG" >&2
    exit 1
fi

# Avoid accidentally passing an unrelated file as a Pro attach config. Do not
# print the matching line because it contains the subscription token.
if ! grep -Eq '^[[:space:]]*token[[:space:]]*:' "$ATTACH_CONFIG"; then
    echo "Attach config does not contain a YAML token field: $ATTACH_CONFIG" >&2
    exit 1
fi

echo "Building $IMAGE_TAG with Buildah"
echo "Using attach config as a build secret: $ATTACH_CONFIG"

exec buildah bud \
    --no-cache \
    --force-rm \
    --format docker \
    --file "$CONTAINERFILE" \
    --tag "$IMAGE_TAG" \
    --secret "id=pro-attach-config,src=$ATTACH_CONFIG" \
    "$CONTEXT_DIR"
