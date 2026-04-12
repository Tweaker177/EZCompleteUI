#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Iterable, Tuple

IMPORTS_TO_ADD = [
    '#import "EZBubbleCell.h"',
    '#import "EZSystemCell.h"',
    '#import "EZCodeBlockCell.h"',
    '#import "EZModelPickerViewController.h"',
    '#import "EZImageSettingsViewController.h"',
    '#import "ViewController+EZTitleFix.h"',
]

MAKEFILE_INSERT = [
    'EZBubbleCell.m',
    'EZSystemCell.m',
    'EZCodeBlockCell.m',
    'EZModelPickerViewController.m',
    'EZImageSettingsViewController.m',
    'ViewController+EZTitleFix.m',
]

BLOCK_PATTERNS = [
    (r'@interface\s+EZBubbleCell\b.*?@end\s*@implementation\s+EZBubbleCell\b.*?@end\s*', 'EZBubbleCell block'),
    (r'@interface\s+EZSystemCell\b.*?@end\s*@implementation\s+EZSystemCell\b.*?@end\s*', 'EZSystemCell block'),
    (r'@interface\s+EZCodeBlockCell\b.*?@end\s*@implementation\s+EZCodeBlockCell\b.*?@end\s*', 'EZCodeBlockCell block'),
    (r'@interface\s+EZModelPickerViewController\b.*?@end\s*@implementation\s+EZModelPickerViewController\b.*?@end\s*', 'EZModelPickerViewController block'),
    (r'@interface\s+EZImageSettingsViewController\b.*?@end\s*@implementation\s+EZImageSettingsViewController\b.*?@end\s*', 'EZImageSettingsViewController block'),
    (r'@interface\s+ViewController\s*\(EZTitleFix\)\s*@end\s*@implementation\s+ViewController\s*\(EZTitleFix\)\b.*?@end\s*', 'EZTitleFix category block'),
]


def add_imports(viewcontroller_text: str) -> Tuple[str, bool]:
    changed = False
    lines = viewcontroller_text.splitlines()

    existing = set(lines)
    missing = [imp for imp in IMPORTS_TO_ADD if imp not in existing]
    if not missing:
        return viewcontroller_text, False

    insert_after = None
    for i, line in enumerate(lines):
        if line.strip().startswith('#import '):
            insert_after = i
    if insert_after is None:
        raise RuntimeError('Could not find import section in ViewController.m')

    for offset, imp in enumerate(missing, start=1):
        lines.insert(insert_after + offset, imp)
    changed = True
    return '\n'.join(lines) + ('\n' if viewcontroller_text.endswith('\n') else ''), changed



def remove_embedded_blocks(viewcontroller_text: str) -> Tuple[str, list[str]]:
    removed: list[str] = []
    updated = viewcontroller_text

    for pattern, label in BLOCK_PATTERNS:
        new_text, count = re.subn(pattern, '', updated, flags=re.S)
        if count > 0:
            updated = new_text
            removed.append(label)

    if not removed:
        raise RuntimeError('Did not find any embedded class/category blocks to remove')

    updated = re.sub(r'\n{4,}', '\n\n\n', updated)
    return updated, removed



def patch_makefile(makefile_text: str) -> Tuple[str, bool]:
    match = re.search(r'^(EZCompleteUI_FILES\s*=\s*)(.+)$', makefile_text, flags=re.M)
    if not match:
        raise RuntimeError('Could not find EZCompleteUI_FILES in Makefile')

    prefix = match.group(1)
    value = match.group(2).strip()
    tokens = value.split()

    changed = False
    for item in MAKEFILE_INSERT:
        if item not in tokens:
            try:
                vc_index = tokens.index('ViewController.m')
                tokens.insert(vc_index + 1, item)
            except ValueError:
                tokens.append(item)
            changed = True

    if not changed:
        return makefile_text, False

    rebuilt = prefix + ' '.join(tokens)
    start, end = match.span()
    return makefile_text[:start] + rebuilt + makefile_text[end:], True



def write_text(path: pathlib.Path, text: str, dry_run: bool) -> None:
    if dry_run:
        return
    path.write_text(text, encoding='utf-8')



def main(argv: Iterable[str]) -> int:
    parser = argparse.ArgumentParser(
        description='Split embedded classes out of ViewController.m and update Makefile.'
    )
    parser.add_argument('repo_root', nargs='?', default='.', help='Path to EZCompleteUI repo root')
    parser.add_argument('--viewcontroller', default='ViewController.m', help='Relative path to ViewController.m')
    parser.add_argument('--makefile', default='Makefile', help='Relative path to Makefile')
    parser.add_argument('--output-viewcontroller', default=None, help='Optional output path for patched ViewController.m')
    parser.add_argument('--output-makefile', default=None, help='Optional output path for patched Makefile')
    parser.add_argument('--dry-run', action='store_true', help='Validate and report changes without writing files')
    args = parser.parse_args(list(argv))

    root = pathlib.Path(args.repo_root).resolve()
    vc_path = (root / args.viewcontroller).resolve()
    mk_path = (root / args.makefile).resolve()

    if not vc_path.exists():
        raise FileNotFoundError(f'ViewController file not found: {vc_path}')
    if not mk_path.exists():
        raise FileNotFoundError(f'Makefile not found: {mk_path}')

    original_vc = vc_path.read_text(encoding='utf-8')
    original_mk = mk_path.read_text(encoding='utf-8')

    vc_with_imports, imports_changed = add_imports(original_vc)
    patched_vc, removed = remove_embedded_blocks(vc_with_imports)
    patched_mk, mk_changed = patch_makefile(original_mk)

    out_vc = (root / args.output_viewcontroller).resolve() if args.output_viewcontroller else vc_path
    out_mk = (root / args.output_makefile).resolve() if args.output_makefile else mk_path

    write_text(out_vc, patched_vc, args.dry_run)
    write_text(out_mk, patched_mk, args.dry_run)

    print('Patched ViewController:', out_vc)
    print('Patched Makefile:', out_mk)
    print('Added imports:', 'yes' if imports_changed else 'already present')
    print('Removed blocks:')
    for label in removed:
        print(' -', label)
    print('Updated Makefile:', 'yes' if mk_changed else 'already present')
    if args.dry_run:
        print('Dry run only, no files written.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        raise SystemExit(1)
