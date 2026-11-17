#!/bin/sh
# Regenerates the AEA test fixtures with a throwaway certificate chain. Run from this folder.
set -e
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
key() { openssl ecparam -name prime256v1 -genkey -noout -out "$work/$1.key"; }
key root; key inter; key leaf; key other
openssl req -x509 -new -key "$work/root.key" -subj "/CN=XCInfo Test Root/O=xcinfo tests" -days 36500 -sha256 -out root.pem \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n" > "$work/ca.ext"
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n" > "$work/leaf.ext"
openssl req -new -key "$work/inter.key" -subj "/CN=XCInfo Test Signing CA/O=xcinfo tests" -out "$work/inter.csr"
openssl x509 -req -in "$work/inter.csr" -CA root.pem -CAkey "$work/root.key" -CAcreateserial -CAserial "$work/root.srl" -days 36500 -sha256 -extfile "$work/ca.ext" -out "$work/inter.pem"
openssl req -new -key "$work/leaf.key" -subj "/CN=XCInfo Test Leaf/O=xcinfo tests" -out "$work/leaf.csr"
openssl x509 -req -in "$work/leaf.csr" -CA "$work/inter.pem" -CAkey "$work/inter.key" -CAcreateserial -CAserial "$work/inter.srl" -days 36500 -sha256 -extfile "$work/leaf.ext" -out "$work/leaf.pem"
cat "$work/leaf.pem" "$work/inter.pem" root.pem > "$work/chain.pem"
mkdir -p "$work/src/Xcode-beta.app/Contents"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.apple.dt.Xcode" "$work/src/Xcode-beta.app/Contents/Info.plist" > /dev/null
echo payload > "$work/src/Xcode-beta.app/Contents/payload.txt"
aa archive -d "$work/src" -o "$work/payload.aar" -a raw
chain="-auth-data-key com.apple.ias.signature.certificate-chain -auth-data $work/chain.pem"
aea encrypt -profile 0 -i "$work/payload.aar" -o signed.aea -sign-priv "$work/leaf.key" $chain
aea encrypt -profile 0 -i "$work/payload.aar" -o wrong-signer.aea -sign-priv "$work/other.key" $chain
aea encrypt -profile 1 -i "$work/payload.aar" -o symmetric.aea -key "$work/sym.key" -key-gen
