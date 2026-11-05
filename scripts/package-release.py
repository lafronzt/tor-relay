#!/usr/bin/env python3
"""Build a source-only archive; exclude local config and filesystem identity."""
import argparse
import gzip
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
FILES = {
    '.gitignore', '.dockerignore', 'README.md', 'LICENSE', 'SECURITY.md',
    'CONTRIBUTING.md', 'CHANGELOG.md', 'values.example.yaml',
}
DIRECTORIES = {'.github', 'charts', 'docs', 'image', 'scripts', 'tests'}
FORBIDDEN_PARTS = {'keys', 'data', 'backups', 'private', 'secrets', '.kube',
                   '.aws', '.ssh', '.git', '.codex', '.agents'}
FORBIDDEN_SUFFIXES = {'.key', '.pem', '.age', '.log', '.p12', '.pfx', '.tar', '.gz'}


def public_files():
    found = []
    for name in sorted(FILES | DIRECTORIES):
        start = ROOT / name
        if start.is_symlink():
            raise ValueError(f'symlink in release inputs: {name}')
        if not start.exists():
            raise ValueError(f'missing release input: {name}')
        candidates = [start] if start.is_file() else sorted(start.rglob('*'))
        for path in candidates:
            rel = path.relative_to(ROOT)
            if path.is_symlink():
                raise ValueError(f'symlink in release inputs: {rel}')
            if '__pycache__' in rel.parts or path.suffix == '.pyc':
                continue
            if path.is_dir():
                continue
            if (FORBIDDEN_PARTS.intersection(rel.parts)
                    or path.suffix in FORBIDDEN_SUFFIXES
                    or path.name.startswith('.env')
                    or '.local.' in path.name
                    or path.name.startswith('rendered')):
                raise ValueError(f'private/generated file in source directory: {rel}')
            data = path.read_bytes()
            text = data.decode('utf-8')  # Binary artifacts never belong in source.
            if re.search(r'/(?:Users|home)/[A-Za-z0-9_.-]+/', text):
                raise ValueError(f'personal home path in source: {rel}')
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
                raise ValueError(f'private key in source: {rel}')
            found.append((rel, path, data))
    # A GitHub push exposes every tracked file, not only this source archive.
    tracked = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z'],
                             capture_output=True, check=False)
    if tracked.returncode == 0:
        approved = {str(rel) for rel, _, _ in found}
        extra = {p for p in tracked.stdout.decode().split('\0') if p} - approved
        if extra:
            raise ValueError('tracked files outside public source allowlist: '
                             + ', '.join(sorted(extra)))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    files = public_files()
    output = args.output.resolve()
    if output in {p.resolve() for _, p, _ in files}:
        raise ValueError('output would replace a source file')
    # No host username/group, absolute path, extended attributes or timestamp.
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '0'))
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=epoch) as zipped:
            with tarfile.open(fileobj=zipped, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for rel, path, data in files:
                    entry = tarfile.TarInfo('tor-relay/' + rel.as_posix())
                    entry.size = len(data)
                    entry.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                    entry.mtime = epoch
                    archive.addfile(entry, io.BytesIO(data))
    print(f'Created source archive with {len(files)} files. Run Gitleaks on the sources and Git history before publishing.')


if __name__ == '__main__':
    main()
