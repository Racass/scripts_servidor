#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

PATTERNS = [
    re.compile(r'AKIA[0-9A-Z]{16}'),
    re.compile(r'AIza[0-9A-Za-z_-]{35}'),
    re.compile(r'gh[pousr]_[A-Za-z0-9]{20,}'),
    re.compile(r'github_pat_[A-Za-z0-9_]{20,}'),
    re.compile(r'xox[baprs]-[A-Za-z0-9-]{10,}'),
    re.compile(r'-----BEGIN (?:RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----'),
]
KEY_ASSIGNMENT_RE = re.compile(
    r'(?i)(?:^|[\s])(?:mysql_root_password|mysql_password|nextcloud_admin_password|aws_access_key_id|aws_secret_access_key|client_secret|secret_access_key|access_token|refresh_token|password)\s*[:=]\s*(.+)$'
)


def run_git(*args: str) -> str:
    result = subprocess.run(['git', *args], cwd=ROOT, capture_output=True)
    if result.returncode not in (0, 1):
        stderr = result.stderr.decode('utf-8', 'replace').strip()
        stdout = result.stdout.decode('utf-8', 'replace').strip()
        raise RuntimeError(f'git {args} failed: {stderr or stdout}')
    return result.stdout.decode('utf-8', 'replace')


def iter_worktree_files():
    output = run_git('ls-files', '-z')
    for file in output.split('\0'):
        if file:
            yield file


def find_match(content: str):
    if content is None:
        return None
    for pattern in PATTERNS:
        if pattern.search(content):
            return 'token-pattern'
    for line in content.splitlines():
        match = KEY_ASSIGNMENT_RE.search(line)
        if not match:
            continue
        value = match.group(1).strip().strip('"\'')
        if value and not value.startswith(('$', '${', '-', '#')):
            return 'key-assignment'
    return None


def scan_worktree():
    hits = []
    for rel_path in iter_worktree_files():
        file_path = ROOT / rel_path
        try:
            content = file_path.read_text(encoding='utf-8', errors='replace')
        except OSError:
            continue
        match = find_match(content)
        if match:
            hits.append((rel_path, 'worktree'))
    return hits


def scan_history():
    hits = []
    commits = run_git('rev-list', '--all').splitlines()
    for commit in commits:
        message = run_git('log', '-1', '--format=%B', commit)
        match = find_match(message)
        if match:
            hits.append((commit[:12], 'commit-message'))

    objects = run_git('rev-list', '--objects', '--all').splitlines()
    for line in objects:
        if not line:
            continue
        oid, *rest = line.split(' ', 1)
        if not oid:
            continue
        blob = run_git('cat-file', '-p', oid)
        match = find_match(blob)
        if match:
            path = rest[0] if rest else '<object>'
            hits.append((path, 'history-blob'))
    return hits


def main():
    worktree_hits = scan_worktree()
    history_hits = scan_history()
    combined = worktree_hits + history_hits
    if combined:
        print('Credential-like values detected:')
        for path, kind in combined:
            print(f'- {kind}: {path}')
        return 1

    print('No credential-like values found in the working tree or Git history.')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2)
