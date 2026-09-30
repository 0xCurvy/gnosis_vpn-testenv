#!/usr/bin/env bats
# Offline tests for fetch-zk-keys.sh: the "release" is a local directory served by a fake curl.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../fetch-zk-keys.sh"
    TMP="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}"
    RELEASE="${TMP}/release"
    DEST="${TMP}/zk-keys"
    PINS="${TMP}/pins.sha256"
    CURL_LOG="${TMP}/curl.log"
    mkdir -p "${RELEASE}"

    printf 'zkey-a' >"${RELEASE}/a.zkey"
    printf 'graph-b' >"${RELEASE}/b.signet.zst"
    {
        echo "# curvy-sdk 0.1.0-rc.9"
        (cd "${RELEASE}" && shasum -a 256 a.zkey b.signet.zst)
    } >"${PINS}"

    # Fake curl: serve `-o <file> <url>` from RELEASE by basename, logging each URL.
    cat >"${TMP}/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -o) out="\$2"; shift ;;
        http://* | https://*) url="\$1" ;;
    esac
    shift
done
echo "\${url}" >>"${CURL_LOG}"
src="${RELEASE}/\${url##*/}"
[ -f "\${src}" ] || exit 22
cp "\${src}" "\${out}"
EOF
    chmod +x "${TMP}/curl"
    export GVPN_CURL="${TMP}/curl"
}

@test "downloads every pinned file from the release and verifies it" {
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -eq 0 ]
    cmp "${RELEASE}/a.zkey" "${DEST}/a.zkey"
    cmp "${RELEASE}/b.signet.zst" "${DEST}/b.signet.zst"
    [[ "$output" == *"2 of 2 files verified"* ]]
}

@test "fetches from the release of the pinned curvy-sdk version" {
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -eq 0 ]
    grep -qx "https://github.com/0xCurvy/rs-sdk/releases/download/v0.1.0-rc.9/a.zkey" "${CURL_LOG}"
}

@test "skips files that are already present and verified" {
    "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    : >"${CURL_LOG}"
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -eq 0 ]
    [ ! -s "${CURL_LOG}" ]
}

@test "replaces a stale file whose digest no longer matches the pin" {
    mkdir -p "${DEST}"
    printf 'old-evaluation-key' >"${DEST}/a.zkey"
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -eq 0 ]
    cmp "${RELEASE}/a.zkey" "${DEST}/a.zkey"
}

@test "fails and keeps nothing when a download does not match its pin" {
    printf 'tampered' >"${RELEASE}/a.zkey"
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"a.zkey"*"SHA-256 MISMATCH"* ]]
    [ ! -e "${DEST}/a.zkey" ]
}

@test "fails when a pinned file is missing from the release" {
    rm "${RELEASE}/b.signet.zst"
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"b.signet.zst"*"DOWNLOAD FAILED"* ]]
}

@test "leaves the artifacts readable by the unprivileged worker user" {
    (umask 077 && "${SCRIPT}" --dir "${DEST}" --pins "${PINS}")
    [ "$(stat -c %a "${DEST}/a.zkey" 2>/dev/null || stat -f %Lp "${DEST}/a.zkey")" = "644" ]
    [ "$(stat -c %a "${DEST}" 2>/dev/null || stat -f %Lp "${DEST}")" = "755" ]
}

@test "--version overrides the release the pins file names" {
    run "${SCRIPT}" --dir "${DEST}" --pins "${PINS}" --version 0.1.0-rc.10
    [ "$status" -eq 0 ]
    grep -q "/download/v0.1.0-rc.10/a.zkey$" "${CURL_LOG}"
}
