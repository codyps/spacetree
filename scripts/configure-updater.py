#!/usr/bin/env python3
"""Add opt-in Sparkle configuration to a packaged app (never store private keys)."""
import base64
import os
from pathlib import Path
import plistlib
import re
import sys


def configure(info, public_key, repository="codyps/spacetree"):
    if not public_key:
        return info
    try:
        valid_key = len(base64.b64decode(public_key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise ValueError("SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte Ed25519 public key")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    development = "-dev." in info["SpaceTreeDisplayVersion"]
    path = "download/development" if development else "latest/download"
    return dict(info, **{
        "SUFeedURL": f"https://github.com/{repository}/releases/{path}/appcast.xml",
        "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False,
        "SUAutomaticallyUpdate": False,
        "SUEnableSystemProfiling": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUSignedFeedFailureExpirationInterval": 0,
    })


if __name__ == "__main__":
    path = Path(sys.argv[1])
    info = plistlib.loads(path.read_bytes())
    info = configure(info, os.environ.get("SPARKLE_PUBLIC_ED_KEY", ""),
                     os.environ.get("GITHUB_REPOSITORY", "codyps/spacetree"))
    path.write_bytes(plistlib.dumps(info))
