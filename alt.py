#!/usr/bin/env python3
# publish_altstore_source.py
# EZCompleteUI AltStore source publisher v1.0
#
# Purpose:
#   One-time helper that takes the four AltStore files after they have been
#   downloaded into the repo root, puts each one where it belongs, checks them,
#   commits only those files, pushes to main, and confirms the public source
#   URL is serving the new apps.json.
#
#   Final locations:
#     apps.json                                    (repo root)
#     ALTSTORE_SETUP.md                            (repo root)
#     .github/workflows/update-altstore-source.yml
#     .github/scripts/update_altstore_source.py
#
#   Browser downloads often add suffixes such as "apps (1).json"; those are
#   recognised. If a file is already in its final place it is left alone, so
#   the script is safe to run more than once.
#
# Safety:
#   - Only the four files above are committed. Other staged or modified files
#     (for example pending deletions from a cleanup) are not swept in.
#   - Nothing is moved until every file passes validation.
#   - An apps.json that is already in the repo root is never replaced by a
#     renamed download such as "apps (1).json"; the duplicate is ignored with a
#     warning. The release workflow keeps that file up to date, so a stale copy
#     would erase newer versions. To replace it on purpose, delete or rename
#     the old one first.
#
# Usage (run from anywhere inside the EZCompleteUI clone):
#   python3 publish_altstore_source.py [--dry-run] [--skip-online-checks]
#                                      [--message TEXT]
#
# Exit codes:
#   0  files are published (or already were)
#   1  a check failed; nothing was pushed unless the message says otherwise

import argparse
import json
import os
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REQUIRED_BRANCH = "main"
REMOTE_NAME = "origin"
NETWORK_TIMEOUT_SECONDS = 20
RAW_VERIFY_ATTEMPTS = 4
RAW_VERIFY_WAIT_SECONDS = 15

# Each entry: where the file must end up and the filenames it may arrive under
# in the repo root.
FILE_PLAN = [
    {
        "label": "AltStore source",
        "final_path": "apps.json",
        "root_name_pattern": re.compile(r"^apps(?: \(\d+\)| copy(?: \d+)?)?\.json$", re.IGNORECASE),
    },
    {
        "label": "Release workflow",
        "final_path": ".github/workflows/update-altstore-source.yml",
        "root_name_pattern": re.compile(r"^update[-_]altstore[-_]source(?: \(\d+\))?\.ya?ml$", re.IGNORECASE),
    },
    {
        "label": "Updater script",
        "final_path": ".github/scripts/update_altstore_source.py",
        "root_name_pattern": re.compile(r"^update[-_]altstore[-_]source(?: \(\d+\))?\.py$", re.IGNORECASE),
    },
    {
        "label": "Setup guide",
        "final_path": "ALTSTORE_SETUP.md",
        "root_name_pattern": re.compile(r"^ALTSTORE[-_ ]SETUP(?: \(\d+\))?\.md$", re.IGNORECASE),
    },
]


def fail(message):
    print(f"\nERROR: {message}", file=sys.stderr)
    sys.exit(1)


def warn(message):
    print(f"  warning: {message}")


def run_git(arguments, check=True):
    """Runs a git command and returns the CompletedProcess with text output."""
    try:
        result = subprocess.run(["git"] + arguments, capture_output=True, text=True)
    except FileNotFoundError:
        fail("git is not installed or not on your PATH.")
    if check and result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        fail(f"git {' '.join(arguments)} failed:\n{details}")
    return result


def enter_repository_root():
    """Moves into the top of the git checkout so every path below is repo-relative."""
    result = run_git(["rev-parse", "--show-toplevel"], check=False)
    if result.returncode != 0:
        fail("This folder is not inside a git repository. Run the script from your EZCompleteUI clone.")
    os.chdir(result.stdout.strip())


def check_branch_and_remote():
    branch = run_git(["rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
    if branch != REQUIRED_BRANCH:
        fail(f"You are on '{branch}'. The source URL serves the '{REQUIRED_BRANCH}' branch, so switch with:\n"
             f"  git checkout {REQUIRED_BRANCH}")
    if run_git(["remote", "get-url", REMOTE_NAME], check=False).returncode != 0:
        fail(f"No git remote named '{REMOTE_NAME}' is configured.")


def is_ignored(path):
    return run_git(["check-ignore", "-q", "--", path], check=False).returncode == 0


def resolve_plan():
    """Decides, for each file, which existing file supplies its content."""
    plan = []
    for entry in FILE_PLAN:
        final_path = entry["final_path"]
        final_name = os.path.basename(final_path)
        root_candidates = [name for name in os.listdir(".")
                           if os.path.isfile(name) and entry["root_name_pattern"].match(name)]

        # A file already sitting at its final root location wins over renamed
        # duplicates. Comparing against the full final path (not just the
        # basename) matters for nested targets: a root file named exactly like
        # the target still has to be moved into its folder.
        exact_in_root = final_path in root_candidates
        duplicates = sorted((name for name in root_candidates if name != final_path),
                            key=os.path.getmtime, reverse=True)

        if exact_in_root:
            source_path = final_path
            leftovers = duplicates
        elif duplicates:
            source_path = duplicates[0]
            leftovers = duplicates[1:]
        elif os.path.isfile(final_path):
            source_path = final_path
            leftovers = []
        else:
            fail(f"{entry['label']} not found. Expected it in the repo root (looked for a file like "
                 f"'{final_name}').")

        needs_move = os.path.abspath(source_path) != os.path.abspath(final_path)
        plan.append({**entry, "source_path": source_path, "needs_move": needs_move,
                     "leftovers": leftovers, "kept_existing": exact_in_root and bool(duplicates)})
    return plan


def validate_source_json(path, skip_online_checks):
    try:
        with open(path, "r", encoding="utf-8") as source_file:
            source = json.load(source_file)
    except json.JSONDecodeError as error:
        fail(f"{path} is not valid JSON: {error}")

    for key in ("name", "identifier", "apps"):
        if key not in source:
            fail(f"{path} is missing the top-level key '{key}'.")
    if not isinstance(source["apps"], list) or not source["apps"]:
        fail(f"{path} has an empty or invalid 'apps' list.")

    for app in source["apps"]:
        app_label = app.get("bundleIdentifier", "<unknown app>")
        for key in ("name", "bundleIdentifier", "developerName", "versions"):
            if not app.get(key):
                fail(f"App {app_label} is missing '{key}'.")
        for version in app["versions"]:
            version_label = f"{app_label} {version.get('version', '?')}"
            for key in ("version", "buildVersion", "date", "downloadURL", "size", "sha256", "minOSVersion"):
                if key not in version:
                    fail(f"{version_label} is missing '{key}'.")
            if not isinstance(version["size"], int) or version["size"] <= 0:
                fail(f"{version_label} has an invalid size.")
            if not re.fullmatch(r"[0-9a-f]{64}", str(version["sha256"])):
                fail(f"{version_label} has an invalid sha256.")
            if not str(version["downloadURL"]).startswith("https://"):
                fail(f"{version_label} downloadURL must be https.")
            if not skip_online_checks:
                check_download_size(version_label, version["downloadURL"], version["size"])
    return source


def check_download_size(version_label, download_url, expected_size):
    """AltStore refuses installs when the listed size differs from the real file."""
    request = urllib.request.Request(download_url, method="HEAD")
    try:
        with urllib.request.urlopen(request, timeout=NETWORK_TIMEOUT_SECONDS) as response:
            reported_size = response.headers.get("Content-Length")
    except urllib.error.HTTPError as error:
        fail(f"{version_label}: download URL returned HTTP {error.code}. "
             "Check that the release and IPA asset exist and are public.")
    except (urllib.error.URLError, TimeoutError) as error:
        warn(f"could not reach the download URL for {version_label} ({error}); size not verified.")
        return
    if reported_size is None:
        warn(f"{version_label}: server did not report a size; size not verified.")
    elif int(reported_size) != expected_size:
        fail(f"{version_label}: apps.json says {expected_size} bytes but the release asset is "
             f"{reported_size} bytes. AltStore would reject this install.")
    else:
        print(f"  verified {version_label}: {expected_size} bytes match the release asset")


def validate_other_files(plan):
    for entry in plan:
        path = entry["source_path"]
        if entry["final_path"].endswith(".py"):
            # Compile into a temp file so no __pycache__ appears in the repo.
            with tempfile.TemporaryDirectory() as scratch_directory:
                try:
                    py_compile.compile(path, cfile=os.path.join(scratch_directory, "check.pyc"), doraise=True)
                except py_compile.PyCompileError as error:
                    fail(f"{path} has a Python syntax error:\n{error}")
        elif entry["final_path"].endswith((".yml", ".yaml")):
            try:
                import yaml  # optional; the check is skipped when PyYAML is not installed
            except ImportError:
                warn("PyYAML not installed; workflow YAML syntax not checked.")
                continue
            try:
                with open(path, "r", encoding="utf-8") as workflow_file:
                    yaml.safe_load(workflow_file)
            except yaml.YAMLError as error:
                fail(f"{path} is not valid YAML:\n{error}")


def place_files(plan):
    for entry in plan:
        if not entry["needs_move"]:
            continue
        destination = entry["final_path"]
        os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
        shutil.move(entry["source_path"], destination)
        print(f"  moved {entry['source_path']!r} -> {destination}")


def commit_and_push(final_paths, message):
    run_git(["add", "--"] + final_paths)
    if run_git(["diff", "--cached", "--quiet", "--"] + final_paths, check=False).returncode == 0:
        print("  the repo already contains these exact files; nothing new to commit")
        return False

    # Pathspec commit: staged changes to any other file are left out.
    commit_result = run_git(["commit", "-m", message, "--"] + final_paths, check=False)
    if commit_result.returncode != 0:
        details = (commit_result.stderr or commit_result.stdout).strip()
        if "Please tell me who you are" in details or "user.email" in details:
            fail("git has no author identity. Run:\n"
                 '  git config --global user.name "Your Name"\n'
                 '  git config --global user.email "you@example.com"\nthen run this script again.')
        fail(f"git commit failed:\n{details}")
    print("  committed")

    if run_git(["push", REMOTE_NAME, REQUIRED_BRANCH], check=False).returncode != 0:
        # The remote moved (for example the workflow committed). Rebase and retry once.
        print("  push rejected; rebasing onto the remote and retrying")
        rebase_result = run_git(["pull", "--rebase", "--autostash", REMOTE_NAME, REQUIRED_BRANCH], check=False)
        if rebase_result.returncode != 0:
            fail("Could not rebase onto the remote. Your commit is saved locally. Resolve with:\n"
                 f"  git pull --rebase {REMOTE_NAME} {REQUIRED_BRANCH}\n  git push {REMOTE_NAME} {REQUIRED_BRANCH}\n"
                 f"{(rebase_result.stderr or rebase_result.stdout).strip()}")
        push_retry = run_git(["push", REMOTE_NAME, REQUIRED_BRANCH], check=False)
        if push_retry.returncode != 0:
            fail("Push failed twice. Your commit is saved locally. Check your GitHub login and branch "
                 f"protection, then run: git push {REMOTE_NAME} {REQUIRED_BRANCH}\n"
                 f"{(push_retry.stderr or push_retry.stdout).strip()}")
    print("  pushed")
    return True


def verify_public_source(source):
    """Fetches the public URL with a cache-busting query and compares it to the local file."""
    source_url = source.get("sourceURL")
    if not source_url:
        warn("apps.json has no sourceURL, so the public URL was not checked.")
        return
    with open("apps.json", "r", encoding="utf-8") as local_file:
        local_source = json.load(local_file)

    for attempt in range(1, RAW_VERIFY_ATTEMPTS + 1):
        try:
            request = urllib.request.Request(f"{source_url}?nocache={int(time.time())}")
            with urllib.request.urlopen(request, timeout=NETWORK_TIMEOUT_SECONDS) as response:
                if json.loads(response.read().decode("utf-8")) == local_source:
                    print(f"  live: {source_url}")
                    return
                print(f"  attempt {attempt}: the URL is serving an older copy")
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            print(f"  attempt {attempt}: not available yet ({error})")
        if attempt < RAW_VERIFY_ATTEMPTS:
            time.sleep(RAW_VERIFY_WAIT_SECONDS)
    warn("the public URL did not match yet. GitHub's raw host can cache for up to five minutes; "
         f"open {source_url} in a browser shortly to confirm.")


def parse_arguments():
    parser = argparse.ArgumentParser(description="Place, validate, commit and push the AltStore source files.")
    parser.add_argument("--dry-run", action="store_true", help="Show what would happen without changing anything.")
    parser.add_argument("--skip-online-checks", action="store_true", help="Do not contact GitHub to verify download sizes or the live URL.")
    parser.add_argument("--message", default="Add AltStore source and release automation", help="Commit message.")
    return parser.parse_args()


def main():
    arguments = parse_arguments()

    enter_repository_root()
    check_branch_and_remote()
    print(f"Repository: {os.getcwd()}")

    print("\n[1/5] Locating files")
    plan = resolve_plan()
    for entry in plan:
        action = f"move from {entry['source_path']!r}" if entry["needs_move"] else "already in place"
        print(f"  {entry['label']:<17} {entry['final_path']}  ({action})")
        for leftover in entry["leftovers"]:
            if entry["kept_existing"]:
                warn(f"{leftover!r} was ignored because {entry['final_path']} already exists. "
                     "If the download is the one you want, delete or rename the existing file and run again.")
            else:
                warn(f"{leftover!r} was ignored; a newer download of the same file was used instead")

    ignored = [entry["final_path"] for entry in plan if is_ignored(entry["final_path"])]
    if ignored:
        fail("Your .gitignore would exclude these files, so they could never be committed: "
             f"{', '.join(ignored)}")

    print("\n[2/5] Validating")
    apps_entry = next(entry for entry in plan if entry["final_path"] == "apps.json")
    source = validate_source_json(apps_entry["source_path"], arguments.skip_online_checks)
    validate_other_files(plan)
    print("  all files passed")

    if arguments.dry_run:
        print("\nDry run: nothing was moved, committed, or pushed.")
        return

    print("\n[3/5] Placing files")
    place_files(plan)

    print("\n[4/5] Committing and pushing")
    committed = commit_and_push([entry["final_path"] for entry in plan], arguments.message)

    print("\n[5/5] Checking the public URL")
    if arguments.skip_online_checks:
        print("  skipped")
    else:
        verify_public_source(source)

    print("\nDone." if committed else "\nDone. Nothing changed.")


if __name__ == "__main__":
    main()
