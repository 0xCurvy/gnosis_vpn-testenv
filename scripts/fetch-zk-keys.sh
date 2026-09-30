#!/usr/bin/env bash
# Fetch the Curvy proving artifacts (zkeys + witness graphs) the client's PIX pool proves
# with, from the rs-sdk release they were published in, and authenticate every file against
# a pinned SHA-256. The result is the flat directory curvy-witnesscalc reads through
# CURVY_ZK_KEYS_DIR. Already-verified files are kept, so re-running is cheap.
set -euo pipefail

readonly RELEASES_URL="https://github.com/0xCurvy/rs-sdk/releases/download"
readonly DEFAULT_DIR="/tmp/gnosis_vpn-testenv-zk-keys"
DEFAULT_PINS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/zk-keys.sha256"
readonly DEFAULT_PINS

CURL="${GVPN_CURL:-curl}"
DIR="${DEFAULT_DIR}"
PINS="${DEFAULT_PINS}"
VERSION=""

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dir DIR] [--pins FILE] [--version VERSION]

  --dir DIR          where to place the artifacts (default: ${DEFAULT_DIR})
  --pins FILE        sha256sum-format pins; a '# curvy-sdk <version>' header names the
                     rs-sdk release to fetch from (default: ${DEFAULT_PINS})
  --version VERSION  fetch from this rs-sdk release instead of the one the pins name
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) DIR="$2"; shift 2 ;;
        --pins) PINS="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if command -v sha256sum >/dev/null 2>&1; then
    digest() { sha256sum "$1" | awk '{print $1}'; }
else
    digest() { shasum -a 256 "$1" | awk '{print $1}'; }
fi

[[ -f ${PINS} ]] || { echo "pins file not found: ${PINS}" >&2; exit 1; }
if [[ -z ${VERSION} ]]; then
    VERSION="$(sed -n 's/^# curvy-sdk \(.*\)$/\1/p' "${PINS}" | head -1)"
    [[ -n ${VERSION} ]] || { echo "${PINS} names no '# curvy-sdk <version>'; pass --version" >&2; exit 1; }
fi
base_url="${RELEASES_URL}/v${VERSION}"

mkdir -p "${DIR}"
chmod 0755 "${DIR}"
total=0
verified=0
failures=0
while read -r expected name; do
    [[ -z ${expected} || ${expected} == \#* ]] && continue
    total=$((total + 1))
    target="${DIR}/${name}"
    if [[ -f ${target} ]] && [[ "$(digest "${target}")" == "${expected}" ]]; then
        verified=$((verified + 1))
        continue
    fi

    # Download beside the target and move it into place only once it authenticates, so a
    # failed or tampered download never leaves a file that looks usable.
    partial="${target}.partial"
    rm -f "${partial}"
    if ! "${CURL}" -fsSL --retry 3 -o "${partial}" "${base_url}/${name}"; then
        printf '  %-52s DOWNLOAD FAILED (%s)\n' "${name}" "${base_url}/${name}"
        rm -f "${partial}" "${target}"
        failures=$((failures + 1))
        continue
    fi
    got="$(digest "${partial}")"
    if [[ ${got} != "${expected}" ]]; then
        printf '  %-52s SHA-256 MISMATCH\n    expected %s\n    got      %s\n' "${name}" "${expected}" "${got}"
        rm -f "${partial}" "${target}"
        failures=$((failures + 1))
        continue
    fi
    # gnosis_vpn-worker proves as an unprivileged user; these are public release artifacts.
    chmod 0644 "${partial}"
    mv "${partial}" "${target}"
    printf '  %-52s ok\n' "${name}"
    verified=$((verified + 1))
done <"${PINS}"

echo "zk keys: ${verified} of ${total} files verified in ${DIR} (curvy-sdk v${VERSION})"
[[ ${failures} -eq 0 && ${verified} -eq ${total} ]]
