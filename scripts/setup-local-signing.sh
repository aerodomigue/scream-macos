#!/bin/bash
# Keep signing material and the single-identity keychain inside this project.
set -euo pipefail
umask 077

readonly IDENTITY_NAME='ScreamBar Local Signing'
readonly CERTIFICATE_VALIDITY_DAYS=3650
readonly RSA_KEY_BITS=3072
readonly PASSWORD_BYTES=32
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
readonly PROJECT_ROOT
readonly PRIVATE_KEY="$PROJECT_ROOT/.screambar-signing.key"
readonly CERTIFICATE="$PROJECT_ROOT/.screambar-signing.crt"
readonly PASSWORD_FILE="$PROJECT_ROOT/.screambar-signing.password"
readonly PROJECT_KEYCHAIN="$PROJECT_ROOT/.screambar-signing.keychain-db"
readonly SETUP_MODE="${1:-setup}"
if [[ "$SETUP_MODE" != setup && "$SETUP_MODE" != --check ]]; then
    printf 'Usage: %s [--check]\n' "$0" >&2
    exit 1
fi

for signing_file in "$PRIVATE_KEY" "$CERTIFICATE" "$PASSWORD_FILE" "$PROJECT_KEYCHAIN"; do
    if [[ -L "$signing_file" ]]; then
        printf 'Signing files must be local files, not symbolic links: %s\n' "$signing_file" >&2
        exit 1
    fi
done

if [[ ! -e "$PRIVATE_KEY" && ! -e "$CERTIFICATE" && ! -e "$PASSWORD_FILE" && ! -e "$PROJECT_KEYCHAIN" ]]; then
    if [[ "$SETUP_MODE" == --check ]]; then
        printf 'Project signing material is missing. Restore it, or run make setup-signing for a new identity.\n' >&2
        exit 1
    fi
    /usr/bin/openssl rand -hex "$PASSWORD_BYTES" > "$PASSWORD_FILE"
    /usr/bin/openssl genrsa -aes256 -passout "file:$PASSWORD_FILE" -out "$PRIVATE_KEY" "$RSA_KEY_BITS"
    /usr/bin/openssl req -x509 -new -sha256 -key "$PRIVATE_KEY" -passin "file:$PASSWORD_FILE" \
        -days "$CERTIFICATE_VALIDITY_DAYS" -subj "/CN=${IDENTITY_NAME}" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=critical,codeSigning' -out "$CERTIFICATE"
fi

for signing_file in "$PRIVATE_KEY" "$CERTIFICATE" "$PASSWORD_FILE"; do
    if [[ ! -s "$signing_file" ]]; then
        printf 'Signing material is incomplete. Restore the existing .screambar-signing.* files; do not regenerate the identity.\n' >&2
        exit 1
    fi
    chmod 600 "$signing_file"
done

KEY_PUBLIC_DIGEST=$(/usr/bin/openssl rsa -in "$PRIVATE_KEY" -passin "file:$PASSWORD_FILE" -pubout -outform DER 2>/dev/null | /usr/bin/openssl dgst -sha256)
CERTIFICATE_PUBLIC_DIGEST=$(/usr/bin/openssl x509 -in "$CERTIFICATE" -pubkey -noout | /usr/bin/openssl pkey -pubin -outform DER | /usr/bin/openssl dgst -sha256)
if [[ "$KEY_PUBLIC_DIGEST" != "$CERTIFICATE_PUBLIC_DIGEST" ]]; then
    printf 'The signing key does not match the certificate. No identity was changed.\n' >&2
    exit 1
fi

SIGNING_PASSWORD=$(cat "$PASSWORD_FILE")
if [[ ! -e "$PROJECT_KEYCHAIN" ]]; then
    /usr/bin/security create-keychain -p "$SIGNING_PASSWORD" "$PROJECT_KEYCHAIN"
    # create-keychain adds to the global search list; remove only this new entry.
    remaining_keychains=()
    while IFS= read -r keychain_path; do
        if [[ "$keychain_path" != "$PROJECT_KEYCHAIN" ]]; then remaining_keychains+=("$keychain_path"); fi
    done < <(/usr/bin/security list-keychains -d user | /usr/bin/sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    /usr/bin/security list-keychains -d user -s "${remaining_keychains[@]}"
fi
chmod 600 "$PROJECT_KEYCHAIN"
/usr/bin/security unlock-keychain -p "$SIGNING_PASSWORD" "$PROJECT_KEYCHAIN"

FINGERPRINT=$(/usr/bin/openssl x509 -in "$CERTIFICATE" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')
if ! /usr/bin/security find-identity -p codesigning "$PROJECT_KEYCHAIN" | /usr/bin/grep -Fq "$FINGERPRINT"; then
    if /usr/bin/security find-identity -p codesigning "$PROJECT_KEYCHAIN" | /usr/bin/grep -Eq '[0-9A-F]{40}'; then
        printf 'The project keychain contains another identity. Refusing to replace it.\n' >&2
        exit 1
    fi
    /usr/bin/security import "$PRIVATE_KEY" -k "$PROJECT_KEYCHAIN" -P "$SIGNING_PASSWORD" -t priv -T /usr/bin/codesign
    /usr/bin/security import "$CERTIFICATE" -k "$PROJECT_KEYCHAIN" -f pemseq -t cert
    # Scoped to the project keychain, which contains only ScreamBar's private key.
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -t private -s \
        -k "$SIGNING_PASSWORD" "$PROJECT_KEYCHAIN" >/dev/null
fi
unset SIGNING_PASSWORD
printf 'Project signing identity ready: %s\n' "$FINGERPRINT"
