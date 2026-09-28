#!/usr/bin/env python3
# update_altstore_source.py
# EZCompleteUI AltStore source updater v1.0
#
# Purpose:
#   Keeps apps.json (the AltStore source) in sync with the IPA attached to a
#   GitHub release. It opens the IPA, reads the real bundle identifier, version,
#   build number, minimum iOS version and privacy usage strings out of the
#   bundled Info.plist, measures the file size and SHA-256, and writes a new
#   entry to the app's "versions" list. Older entries are preserved and the list
#   is kept newest-first, which is the order AltStore treats as "latest".
#
#   Every value comes from the IPA itself so the source can never drift from
#   the binary AltStore actually downloads. AltStore rejects an install when
#   the size in the source does not match the file.
#
# Called by:
#   .github/workflows/update-altstore-source.yml
#
# Usage:
#   update_altstore_source.py --source apps.json --ipa EZCompleteUI-7.0.9-release.ipa \
#       --repo Tweaker177/EZCompleteUI --tag v7.0.9 --asset-date 2026-09-20 \
#       [--notes-file notes.txt]
#
# Exit codes:
#   0  source written (or already up to date)
#   1  any validation or I/O failure; the message says what to fix

import argparse
import hashlib
import json
import os
import plistlib
import re
import sys
import tempfile
import zipfile
from urllib.parse import quote

# Matches the app bundle's own Info.plist and nothing nested inside frameworks
# or extensions (those live one or more directories deeper).
INFO_PLIST_PATTERN = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")

# AltStore shows this when a release has no notes of its own.
FALLBACK_NOTES = "See the release page on GitHub for details."

# Keeps the source small; AltStore only shows a short preview anyway.
MAX_NOTES_LENGTH = 2000

CHUNK_SIZE = 1024 * 1024


def fail(message):
    """Prints a GitHub Actions error annotation and exits non-zero."""
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def read_info_plist(ipa_path):
    """Returns the parsed Info.plist dictionary from the app inside the IPA."""
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            matches = [name for name in archive.namelist() if INFO_PLIST_PATTERN.match(name)]
            if len(matches) != 1:
                fail(f"Expected exactly one Payload/<App>.app/Info.plist in the IPA, found {len(matches)}.")
            # plistlib reads both XML and binary plists, and Theos output can be either.
            return plistlib.loads(archive.read(matches[0]))
    except zipfile.BadZipFile:
        fail(f"{ipa_path} is not a valid zip archive, so it is not a valid IPA.")
    except (plistlib.InvalidFileException, ValueError) as error:
        fail(f"Info.plist inside the IPA could not be parsed: {error}")


def compute_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as ipa_file:
        for chunk in iter(lambda: ipa_file.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_source(path):
    try:
        with open(path, "r", encoding="utf-8") as source_file:
            source = json.load(source_file)
    except FileNotFoundError:
        fail(f"{path} does not exist. Commit the initial apps.json before running this.")
    except json.JSONDecodeError as error:
        fail(f"{path} is not valid JSON: {error}")
    if not isinstance(source.get("apps"), list):
        fail(f"{path} has no \"apps\" list.")
    return source


def write_source_atomically(path, source):
    """Writes to a temp file then renames, so a crash never leaves half a JSON file."""
    directory = os.path.dirname(os.path.abspath(path))
    handle, temp_path = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as temp_file:
            json.dump(source, temp_file, indent=2, ensure_ascii=False)
            temp_file.write("\n")
        os.replace(temp_path, path)
    except Exception:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise


def read_notes(notes_path):
    if not notes_path or not os.path.exists(notes_path):
        return FALLBACK_NOTES
    with open(notes_path, "r", encoding="utf-8", errors="replace") as notes_file:
        notes = notes_file.read().strip()
    if not notes:
        return FALLBACK_NOTES
    if len(notes) > MAX_NOTES_LENGTH:
        notes = notes[:MAX_NOTES_LENGTH].rstrip() + "…"
    return notes


def parse_arguments():
    parser = argparse.ArgumentParser(description="Add a release IPA to the AltStore source.")
    parser.add_argument("--source", required=True, help="Path to apps.json")
    parser.add_argument("--ipa", required=True, help="Path to the downloaded IPA")
    parser.add_argument("--repo", required=True, help="GitHub repo as owner/name")
    parser.add_argument("--tag", required=True, help="Release tag the IPA is attached to")
    parser.add_argument("--asset-date", required=True, help="UTC upload date of the IPA, YYYY-MM-DD")
    parser.add_argument("--notes-file", help="Optional file containing the release notes")
    return parser.parse_args()


def main():
    arguments = parse_arguments()

    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", arguments.asset_date):
        fail(f"--asset-date must look like 2026-09-20, got {arguments.asset_date!r}.")
    if not os.path.isfile(arguments.ipa):
        fail(f"IPA not found at {arguments.ipa}.")

    info = read_info_plist(arguments.ipa)
    bundle_identifier = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build_version = info.get("CFBundleVersion")
    minimum_os = info.get("MinimumOSVersion")
    missing = [key for key, value in (("CFBundleIdentifier", bundle_identifier),
                                      ("CFBundleShortVersionString", version),
                                      ("CFBundleVersion", build_version),
                                      ("MinimumOSVersion", minimum_os)) if not value]
    if missing:
        fail(f"Info.plist is missing required keys: {', '.join(missing)}.")

    source = load_source(arguments.source)
    app = next((entry for entry in source["apps"] if entry.get("bundleIdentifier") == bundle_identifier), None)
    if app is None:
        # Refusing here catches a wrong-app upload or a changed bundle ID before
        # it publishes a listing that installs as a different app.
        known = [entry.get("bundleIdentifier") for entry in source["apps"]]
        fail(f"IPA bundle identifier {bundle_identifier!r} is not in the source (known: {known}).")

    tag_version = arguments.tag.lstrip("vV")
    if not tag_version.startswith(str(version)) and not str(version).startswith(tag_version):
        print(f"::warning::Tag {arguments.tag} does not match the IPA version {version}. "
              "The IPA's own version is what gets published.")

    ipa_name = os.path.basename(arguments.ipa)
    new_entry = {
        "version": str(version),
        "buildVersion": str(build_version),
        "date": arguments.asset_date,
        "localizedDescription": read_notes(arguments.notes_file),
        "downloadURL": f"https://github.com/{arguments.repo}/releases/download/"
                       f"{quote(arguments.tag, safe='')}/{quote(ipa_name, safe='')}",
        "size": os.path.getsize(arguments.ipa),
        "sha256": compute_sha256(arguments.ipa),
        "minOSVersion": str(minimum_os),
    }

    # Re-running for the same release replaces its entry rather than duplicating it.
    remaining = [entry for entry in app.get("versions", [])
                 if not (entry.get("version") == new_entry["version"]
                         and entry.get("buildVersion") == new_entry["buildVersion"])]
    # sorted() is stable, so on an equal date the new entry stays first.
    app["versions"] = sorted([new_entry] + remaining, key=lambda entry: entry.get("date", ""), reverse=True)

    # Privacy strings are shown on the listing. Refresh them only when this
    # release is now the newest one, so backfilling an old tag cannot roll back
    # the permissions list.
    if app["versions"][0] is new_entry:
        privacy = {key: value for key, value in info.items()
                   if key.endswith("UsageDescription") and isinstance(value, str)}
        permissions = app.setdefault("appPermissions", {"entitlements": [], "privacy": {}})
        permissions["privacy"] = dict(sorted(privacy.items()))

    write_source_atomically(arguments.source, source)
    print(f"Source updated: {bundle_identifier} {version} ({build_version}), "
          f"{new_entry['size']} bytes, sha256 {new_entry['sha256'][:12]}…")


if __name__ == "__main__":
    main()
