#!/usr/bin/env python3
"""
patch_helpers.py — Fixes helpers.m for EZCompleteUI
Run from the same directory as helpers.m:
    python3 patch_helpers.py

Or pass the path explicitly:
    python3 patch_helpers.py /path/to/helpers.m

Changes applied:
  1. Removes any duplicate content (if the file was accidentally doubled).
  2. Replaces the removed sendSynchronousRequest:returningResponse:error:
     with a semaphore-based wrapper around dataTaskWithRequest:completionHandler:
  3. Replaces NSParameterAssert with NSCParameterAssert inside C functions
     (analyzePromptForContext and createMemoryFromCompletion).
"""

import re
import sys
import shutil
from pathlib import Path

# ── Locate the file ──────────────────────────────────────────────────────────
if len(sys.argv) > 1:
    target = Path(sys.argv[1])
else:
    target = Path("helpers.m")

if not target.exists():
    print(f"ERROR: Cannot find {target}")
    sys.exit(1)

# ── Backup ───────────────────────────────────────────────────────────────────
backup = target.with_suffix(".m.bak")
shutil.copy2(target, backup)
print(f"Backup written to {backup}")

src = target.read_text(encoding="utf-8")

# ── Fix 0: Remove duplicate content ─────────────────────────────────────────
# The file marker that starts the real content
MARKER = "// helpers.m\n// EZCompleteUI"
first = src.find(MARKER)
second = src.find(MARKER, first + 1)
if second != -1:
    print(f"Duplicate content detected at byte {second} — truncating to first copy.")
    src = src[:second]

# ── Fix 1: Replace sendSynchronousRequest block ──────────────────────────────
OLD_SYNC = """\
    // Synchronous request — caller is responsible for background thread.
    NSURLResponse *resp = nil;
    NSError *netErr = nil;
    NSData *responseData = [NSURLSession.sharedSession
                            sendSynchronousRequest:req
                            returningResponse:&resp
                            error:&netErr];"""

NEW_SYNC = """\
    // Semaphore-based synchronous wrapper — replaces the removed
    // sendSynchronousRequest:returningResponse:error: API.
    // IMPORTANT: Always call on a background thread to avoid deadlock.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData  *responseData = nil;
    __block NSError *netErr       = nil;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *data,
                                                           NSURLResponse *response,
                                                           NSError *error) {
            responseData = data;
            netErr       = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);"""

if OLD_SYNC in src:
    src = src.replace(OLD_SYNC, NEW_SYNC, 1)
    print("Fix 1 applied: sendSynchronousRequest replaced with semaphore pattern.")
else:
    # Try a looser match in case whitespace differs
    loose = re.search(
        r'// Synchronous request.*?sendSynchronousRequest:req\s+returningResponse:&resp\s+error:&netErr\];',
        src, re.DOTALL
    )
    if loose:
        src = src[:loose.start()] + NEW_SYNC + src[loose.end():]
        print("Fix 1 applied (loose match): sendSynchronousRequest replaced.")
    else:
        print("WARNING: sendSynchronousRequest pattern not found — already fixed or file differs.")

# ── Fix 2: NSParameterAssert → NSCParameterAssert in C functions ─────────────
# We only want to replace inside the two C functions, not inside ObjC methods.
# Strategy: find the function bodies and replace only within them.

def replace_in_c_function(source, func_signature_pattern):
    """Find a C function by signature and replace NSParameterAssert inside it."""
    match = re.search(func_signature_pattern, source)
    if not match:
        return source, False

    start = match.start()
    # Find the opening brace
    brace_pos = source.find('{', match.end())
    if brace_pos == -1:
        return source, False

    # Walk to find the matching closing brace
    depth = 0
    i = brace_pos
    while i < len(source):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                break
        i += 1

    body = source[brace_pos:i+1]
    new_body = body.replace('NSParameterAssert(', 'NSCParameterAssert(')
    count = body.count('NSParameterAssert(')
    return source[:brace_pos] + new_body + source[i+1:], count

changes = 0
src, n = replace_in_c_function(src, r'void\s+analyzePromptForContext\s*\(')
changes += n
src, n = replace_in_c_function(src, r'void\s+createMemoryFromCompletion\s*\(')
changes += n

if changes:
    print(f"Fix 2 applied: {changes} NSParameterAssert → NSCParameterAssert replacement(s).")
else:
    print("Fix 2: No NSParameterAssert found in C functions (already fixed or not present).")

# ── Write result ─────────────────────────────────────────────────────────────
target.write_text(src, encoding="utf-8")
print(f"\nDone. Patched file written to {target}")
print("Original backed up at", backup)
