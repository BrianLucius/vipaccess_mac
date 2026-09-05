#!/bin/bash
#
# Creates a stable self-signed code-signing certificate named "VIPAccess Dev"
# and trusts it for code signing. This gives every build a consistent code
# signature so macOS keychain access is preserved across rebuilds.
#
# Run once per development machine:
#   ./scripts_create_dev_cert.sh
#
set -e

CERT_NAME="VIPAccess Dev"

# Skip if the identity already exists
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "Code-signing identity '$CERT_NAME' already exists. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing certificate '$CERT_NAME'..."
TMPDIR_CERT=$(mktemp -d)

cat > "$TMPDIR_CERT/cert.conf" << 'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions = v3_code_sign
prompt = no
[ req_dn ]
CN = VIPAccess Dev
[ v3_code_sign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# Generate key + self-signed cert (valid 10 years)
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 3650 \
    -config "$TMPDIR_CERT/cert.conf" 2>/dev/null

# Bundle into PKCS#12 (legacy format for macOS compatibility)
openssl pkcs12 -export -legacy \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -out "$TMPDIR_CERT/cert.p12" \
    -passout pass:temppass 2>/dev/null

# Import the identity into the login keychain, allowing codesign to use it
security import "$TMPDIR_CERT/cert.p12" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "temppass" \
    -T /usr/bin/codesign

# Trust the cert for code signing (requires admin password)
security find-certificate -c "$CERT_NAME" -p > "$TMPDIR_CERT/cert.cer"
echo "Adding code-signing trust (you may be prompted for your admin password)..."
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$TMPDIR_CERT/cert.cer"

rm -rf "$TMPDIR_CERT"

echo ""
echo "Done. Verifying:"
security find-identity -v -p codesigning | grep "$CERT_NAME"
