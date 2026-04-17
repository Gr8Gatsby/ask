#!/usr/bin/env python3
"""
Patch the length and EdDSA signature for a specific version in appcast.xml.
Used by staple-release.yml after the CI staple workflow modifies the Sparkle DMG.

Usage: VERSION=x.y.z NEW_SIG=... NEW_LEN=... python3 patch-appcast-signature.py
"""
import re
import os
import sys

version = os.environ["VERSION"]
new_sig = os.environ["NEW_SIG"]
new_len = os.environ["NEW_LEN"]
appcast_path = os.environ.get("APPCAST_PATH", "docs/appcast.xml")

with open(appcast_path) as f:
    content = f.read()

def patch(m):
    b = m.group(0)
    b = re.sub(r'length="[^"]*"', f'length="{new_len}"', b)
    b = re.sub(r'sparkle:edSignature="[^"]*"', f'sparkle:edSignature="{new_sig}"', b)
    return b

patched = re.sub(
    r'<item>.*?<sparkle:shortVersionString>' + re.escape(version) + r'</sparkle:shortVersionString>.*?</item>',
    patch,
    content,
    flags=re.DOTALL,
)

if patched == content:
    print(f"WARNING: no entry found for version {version} in {appcast_path}", file=sys.stderr)
    sys.exit(1)

with open(appcast_path, "w") as f:
    f.write(patched)

print(f"Patched {appcast_path}: version={version} length={new_len} sig={new_sig[:20]}…")
