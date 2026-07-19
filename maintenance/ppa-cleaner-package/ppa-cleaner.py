#!/usr/bin/env python3
"""
ppa-cleaner: detect and safely disable broken Ubuntu Launchpad PPAs.

Design goals:
- Standard-library-only Python.
- Dry-run by default; changes require --apply.
- Tests each PPA source independently with apt-get.
- Supports classic .list files and deb822 .sources files.
- Does not disable transient network/DNS failures by default.
- Creates restorable backups and a JSON manifest before editing.

Examples:
  sudo ./ppa-cleaner.py check
  sudo ./ppa-cleaner.py clean --apply
  sudo ./ppa-cleaner.py clean --apply --policy dead --attempts 3
  sudo ./ppa-cleaner.py backups
  sudo ./ppa-cleaner.py restore latest --apply
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

VERSION = "1.0.0"
DEFAULT_HOST_REGEX = r"(?:ppa\.launchpadcontent\.net|ppa\.launchpad\.net)"

# Conservative classification. "dead" is the strongest signal that a repository
# is gone or does not publish for the current Ubuntu suite.
DEAD_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\b404\s+Not Found\b",
        r"\b410\s+Gone\b",
        r"does not have a Release file",
        r"no longer has a Release file",
    )
]

BROKEN_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\b401\s+Unauthorized\b",
        r"\b403\s+Forbidden\b",
        r"NO_PUBKEY",
        r"EXPKEYSIG",
        r"BADSIG",
        r"repository is not signed",
        r"The repository .* is no longer signed",
        r"Clearsigned file isn't valid",
        r"Malformed entry",
        r"Conflicting values set for option Signed-By",
        r"The list of sources could not be read",
        r"Unable to parse package file",
    )
]

TRANSIENT_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"Temporary failure resolving",
        r"Could not resolve",
        r"Connection timed out",
        r"Could not connect",
        r"Connection failed",
        r"Connection reset",
        r"Network is unreachable",
        r"TLS connection was non-properly terminated",
        r"Could not handshake",
        r"Hash Sum mismatch",
        r"\b502\s+Bad Gateway\b",
        r"\b503\s+Service Unavailable\b",
        r"\b504\s+Gateway Timeout\b",
        r"Undetermined Error",
    )
]

DISABLE_BY_POLICY = {
    "dead": {"dead"},
    "broken": {"dead", "broken"},
    "all": {"dead", "broken", "transient", "unknown"},
}


@dataclasses.dataclass(frozen=True)
class Candidate:
    key: str
    path: Path
    fmt: str  # "list" or "sources"
    location: int  # line number for .list; stanza start line for .sources
    raw: str
    label: str
    start: int  # line index for .list; character offset for .sources
    end: int  # exclusive line index for .list; exclusive character offset for .sources
    file_digest: str


@dataclasses.dataclass
class CheckResult:
    candidate: Candidate
    status: str
    attempts: int
    return_codes: List[int]
    summary: str
    output: str


class CleanerError(RuntimeError):
    pass


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def is_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="surrogateescape")


def write_atomic(path: Path, content: str, reference: Path) -> None:
    """Atomically replace path while preserving mode/ownership from reference."""
    stat = reference.stat()
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, stat.st_mode)
        if hasattr(os, "chown"):
            try:
                os.chown(tmp_path, stat.st_uid, stat.st_gid)
            except PermissionError:
                pass
        os.replace(tmp_path, path)
        try:
            dir_fd = os.open(path.parent, os.O_DIRECTORY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except (AttributeError, OSError):
            pass
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


def source_files(sources_root: Path) -> List[Path]:
    files: List[Path] = []
    main = sources_root / "sources.list"
    if main.is_file():
        files.append(main)
    parts = sources_root / "sources.list.d"
    if parts.is_dir():
        files.extend(sorted(parts.glob("*.list")))
        files.extend(sorted(parts.glob("*.sources")))
    return files


def extract_uri_label(text: str, host_re: re.Pattern[str]) -> str:
    url_match = re.search(r"https?://[^\s]+", text)
    if not url_match:
        return "Launchpad PPA"
    url = url_match.group(0).rstrip(";,)")
    # Common form: https://ppa.launchpadcontent.net/OWNER/PPA/ubuntu
    match = re.search(
        r"https?://(?:ppa\.launchpadcontent\.net|ppa\.launchpad\.net)/([^/\s]+)/([^/\s]+)",
        url,
        re.IGNORECASE,
    )
    if match:
        return f"{match.group(1)}/{match.group(2)}"
    host = host_re.search(url)
    return host.group(0) if host else url


def scan_list_file(path: Path, text: str, host_re: re.Pattern[str], digest: str) -> List[Candidate]:
    found: List[Candidate] = []
    lines = text.splitlines(keepends=True)
    for idx, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if not re.match(r"^deb(?:-src)?(?:\s|\[)", stripped):
            continue
        if not host_re.search(line):
            continue
        line_no = idx + 1
        label = extract_uri_label(line, host_re)
        found.append(
            Candidate(
                key=f"{path}:{line_no}",
                path=path,
                fmt="list",
                location=line_no,
                raw=line if line.endswith("\n") else line + "\n",
                label=label,
                start=idx,
                end=idx + 1,
                file_digest=digest,
            )
        )
    return found


def stanza_spans(text: str) -> Iterable[Tuple[int, int, int, str]]:
    """Yield start offset, end offset, starting line number, and stanza text."""
    # Non-empty blocks separated by one or more blank lines.
    for match in re.finditer(r"(?ms)(?:^|(?<=\n))([^\n]*(?:\n(?!\s*\n)[^\n]*)*\n?)", text):
        block = match.group(1)
        if not block.strip():
            continue
        start, end = match.span(1)
        line_no = text.count("\n", 0, start) + 1
        yield start, end, line_no, block


def parse_deb822_fields(stanza: str) -> Dict[str, str]:
    fields: Dict[str, str] = {}
    current: Optional[str] = None
    for raw_line in stanza.splitlines():
        if not raw_line or raw_line.lstrip().startswith("#"):
            continue
        if raw_line[0].isspace() and current:
            fields[current] += " " + raw_line.strip()
            continue
        match = re.match(r"^([A-Za-z0-9-]+):\s*(.*)$", raw_line)
        if match:
            current = match.group(1).lower()
            fields[current] = match.group(2).strip()
    return fields


def scan_sources_file(path: Path, text: str, host_re: re.Pattern[str], digest: str) -> List[Candidate]:
    found: List[Candidate] = []
    for start, end, line_no, stanza in stanza_spans(text):
        fields = parse_deb822_fields(stanza)
        enabled = fields.get("enabled", "yes").strip().lower()
        if enabled in {"no", "false", "0"}:
            continue
        types = fields.get("types", "")
        if not any(token in {"deb", "deb-src"} for token in types.split()):
            continue
        uris = fields.get("uris", "")
        if not host_re.search(uris):
            continue
        label = extract_uri_label(uris, host_re)
        raw = stanza
        if not raw.endswith("\n"):
            raw += "\n"
        found.append(
            Candidate(
                key=f"{path}:stanza@{line_no}",
                path=path,
                fmt="sources",
                location=line_no,
                raw=raw,
                label=label,
                start=start,
                end=end,
                file_digest=digest,
            )
        )
    return found


def scan_candidates(sources_root: Path, host_regex: str) -> List[Candidate]:
    try:
        host_re = re.compile(host_regex, re.IGNORECASE)
    except re.error as exc:
        raise CleanerError(f"Invalid --host-regex: {exc}") from exc

    candidates: List[Candidate] = []
    for path in source_files(sources_root):
        try:
            raw_bytes = path.read_bytes()
            digest = sha256_bytes(raw_bytes)
            text = raw_bytes.decode("utf-8", errors="surrogateescape")
        except OSError as exc:
            raise CleanerError(f"Cannot read {path}: {exc}") from exc
        if path.suffix == ".sources":
            candidates.extend(scan_sources_file(path, text, host_re, digest))
        else:
            candidates.extend(scan_list_file(path, text, host_re, digest))
    return candidates


def classify_failure(output: str) -> str:
    if any(pattern.search(output) for pattern in DEAD_PATTERNS):
        return "dead"
    if any(pattern.search(output) for pattern in BROKEN_PATTERNS):
        return "broken"
    if any(pattern.search(output) for pattern in TRANSIENT_PATTERNS):
        return "transient"
    return "unknown"


def concise_output(output: str, limit: int = 320) -> str:
    interesting: List[str] = []
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(("Err:", "E:", "W:", "Ign:", "Get:")) or any(
            token.lower() in stripped.lower()
            for token in ("release file", "not found", "forbidden", "unauthorized", "resolve", "connect", "signature", "public key")
        ):
            interesting.append(stripped)
    summary = " | ".join(interesting[-3:]) if interesting else "apt-get update failed"
    return summary if len(summary) <= limit else summary[: limit - 3] + "..."


def apt_test_once(candidate: Candidate, apt_get: str, timeout: int) -> Tuple[int, str]:
    with tempfile.TemporaryDirectory(prefix="ppa-cleaner-") as tmp:
        root = Path(tmp)
        source_path = root / ("candidate.sources" if candidate.fmt == "sources" else "candidate.list")
        source_path.write_text(candidate.raw, encoding="utf-8", errors="surrogateescape")
        lists_dir = root / "lists"
        cache_dir = root / "cache"
        (lists_dir / "partial").mkdir(parents=True)
        (cache_dir / "archives" / "partial").mkdir(parents=True)

        cmd = [
            apt_get,
            "-o", f"Dir::Etc::sourcelist={source_path}",
            "-o", "Dir::Etc::sourceparts=-",
            "-o", f"Dir::State::lists={lists_dir}",
            "-o", f"Dir::Cache={cache_dir}",
            "-o", "Debug::NoLocking=true",
            "-o", "APT::Get::List-Cleanup=false",
            "-o", "Acquire::Retries=0",
            "-o", f"Acquire::http::Timeout={timeout}",
            "-o", f"Acquire::https::Timeout={timeout}",
            "-o", "APT::Update::Error-Mode=any",
            # We only need Release/InRelease metadata to decide whether the PPA is usable.
            # Disabling package-index targets keeps routine checks fast and lightweight.
            "-o", "Acquire::IndexTargets::deb::Packages::DefaultEnabled=false",
            "-o", "Acquire::IndexTargets::deb::Translations::DefaultEnabled=false",
            "-o", "Acquire::IndexTargets::deb::DEP-11::DefaultEnabled=false",
            "-o", "Acquire::IndexTargets::deb-src::Sources::DefaultEnabled=false",
            "update",
        ]
        env = os.environ.copy()
        env.update({"LC_ALL": "C", "LANG": "C", "DEBIAN_FRONTEND": "noninteractive"})
        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                timeout=max(timeout * 3, timeout + 15),
                env=env,
                check=False,
            )
            return proc.returncode, proc.stdout
        except subprocess.TimeoutExpired as exc:
            output = (exc.stdout or "") + "\nppa-cleaner: test timed out"
            return 124, output
        except OSError as exc:
            return 127, f"ppa-cleaner: failed to run {apt_get}: {exc}"


def check_candidate(candidate: Candidate, apt_get: str, timeout: int, attempts: int) -> CheckResult:
    codes: List[int] = []
    outputs: List[str] = []
    statuses: List[str] = []
    for _ in range(attempts):
        code, output = apt_test_once(candidate, apt_get, timeout)
        codes.append(code)
        outputs.append(output)
        if code == 0:
            return CheckResult(candidate, "ok", len(codes), codes, "reachable", output)
        statuses.append(classify_failure(output))

    # Prefer permanent diagnoses if present; otherwise preserve transient/unknown.
    if "dead" in statuses:
        status = "dead"
    elif "broken" in statuses:
        status = "broken"
    elif "transient" in statuses:
        status = "transient"
    else:
        status = "unknown"
    merged = "\n\n--- attempt ---\n".join(outputs)
    return CheckResult(candidate, status, len(codes), codes, concise_output(merged), merged)


def run_checks(
    candidates: Sequence[Candidate], apt_get: str, timeout: int, attempts: int, jobs: int
) -> List[CheckResult]:
    if not Path(apt_get).exists() and shutil.which(apt_get) is None:
        raise CleanerError(f"apt-get executable not found: {apt_get}")
    results: List[CheckResult] = []
    workers = max(1, min(jobs, len(candidates) or 1))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(check_candidate, candidate, apt_get, timeout, attempts): candidate
            for candidate in candidates
        }
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    results.sort(key=lambda item: (str(item.candidate.path), item.candidate.location))
    return results


def format_location(candidate: Candidate) -> str:
    unit = "line" if candidate.fmt == "list" else "stanza"
    return f"{candidate.path}:{unit} {candidate.location}"


def print_results(results: Sequence[CheckResult], verbose: bool = False) -> None:
    if not results:
        print("No active matching PPA entries found.")
        return
    width = max(7, max(len(result.status.upper()) for result in results))
    for result in results:
        print(f"{result.status.upper():<{width}}  {result.candidate.label:<32}  {format_location(result.candidate)}")
        if result.status != "ok":
            print(f"{'':<{width}}  {result.summary}")
        if verbose:
            print("-" * 88)
            print(result.output.rstrip())
            print("-" * 88)


def disable_list_entries(text: str, candidates: Sequence[Candidate], stamp: str, statuses: Dict[str, str]) -> str:
    lines = text.splitlines(keepends=True)
    for candidate in sorted(candidates, key=lambda item: item.start, reverse=True):
        original = lines[candidate.start]
        newline = "\n" if original.endswith("\n") else ""
        body = original[:-1] if newline else original
        marker = f"# ppa-cleaner: disabled {stamp}; status={statuses[candidate.key]}\n"
        lines[candidate.start : candidate.end] = [marker, "# " + body + newline]
    return "".join(lines)


def disable_sources_entries(text: str, candidates: Sequence[Candidate], stamp: str, statuses: Dict[str, str]) -> str:
    for candidate in sorted(candidates, key=lambda item: item.start, reverse=True):
        stanza = text[candidate.start : candidate.end]
        marker = f"# ppa-cleaner: disabled {stamp}; status={statuses[candidate.key]}"
        enabled_re = re.compile(r"(?im)^Enabled:\s*.*$")
        if enabled_re.search(stanza):
            stanza = enabled_re.sub("Enabled: no", stanza, count=1)
            if marker not in stanza:
                if not stanza.endswith("\n"):
                    stanza += "\n"
                stanza += marker + "\n"
        else:
            if not stanza.endswith("\n"):
                stanza += "\n"
            stanza += f"Enabled: no\n{marker}\n"
        text = text[: candidate.start] + stanza + text[candidate.end :]
    return text


def relative_source_path(path: Path, sources_root: Path) -> Path:
    try:
        return path.resolve().relative_to(sources_root.resolve())
    except ValueError:
        return Path(path.name)


def create_backup(
    backup_root: Path,
    sources_root: Path,
    touched: Dict[Path, Tuple[str, str]],
    results: Sequence[CheckResult],
    policy: str,
) -> Path:
    stamp = utc_stamp()
    backup_dir = backup_root / stamp
    # Avoid a collision if invoked twice in one second.
    suffix = 1
    while backup_dir.exists():
        backup_dir = backup_root / f"{stamp}-{suffix}"
        suffix += 1
    files_dir = backup_dir / "files"
    files_dir.mkdir(parents=True, exist_ok=False)

    manifest_files = []
    for path, (before_text, after_text) in touched.items():
        rel = relative_source_path(path, sources_root)
        destination = files_dir / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(before_text, encoding="utf-8", errors="surrogateescape")
        shutil.copystat(path, destination, follow_symlinks=True)
        manifest_files.append(
            {
                "source": str(path),
                "backup": str(Path("files") / rel),
                "sha256_before": sha256_bytes(before_text.encode("utf-8", errors="surrogateescape")),
                "sha256_after": sha256_bytes(after_text.encode("utf-8", errors="surrogateescape")),
            }
        )

    manifest = {
        "version": VERSION,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "hostname": socket.gethostname(),
        "policy": policy,
        "files": manifest_files,
        "disabled": [
            {
                "key": result.candidate.key,
                "label": result.candidate.label,
                "status": result.status,
                "location": format_location(result.candidate),
                "summary": result.summary,
            }
            for result in results
        ],
    }
    (backup_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return backup_dir


def apply_cleanup(
    results: Sequence[CheckResult],
    policy: str,
    sources_root: Path,
    backup_root: Path,
) -> Optional[Path]:
    selected = [result for result in results if result.status in DISABLE_BY_POLICY[policy]]
    if not selected:
        print(f"Nothing qualifies for disabling under policy '{policy}'.")
        return None
    if not is_root():
        raise CleanerError("Applying changes requires root. Re-run with sudo.")

    grouped: Dict[Path, List[Candidate]] = {}
    statuses: Dict[str, str] = {}
    for result in selected:
        grouped.setdefault(result.candidate.path, []).append(result.candidate)
        statuses[result.candidate.key] = result.status

    stamp = utc_stamp()
    touched: Dict[Path, Tuple[str, str]] = {}
    for path, candidates in grouped.items():
        current_digest = sha256_file(path)
        expected = candidates[0].file_digest
        if current_digest != expected:
            raise CleanerError(f"Refusing to modify {path}: it changed after scanning. Run again.")
        before = read_text(path)
        if path.suffix == ".sources":
            after = disable_sources_entries(before, candidates, stamp, statuses)
        else:
            after = disable_list_entries(before, candidates, stamp, statuses)
        touched[path] = (before, after)

    backup_dir = create_backup(backup_root, sources_root, touched, selected, policy)
    try:
        for path, (_before, after) in touched.items():
            write_atomic(path, after, path)
    except Exception:
        # Best-effort rollback from the backup if an edit fails midway.
        manifest = json.loads((backup_dir / "manifest.json").read_text(encoding="utf-8"))
        for item in manifest["files"]:
            source = Path(item["source"])
            backup = backup_dir / item["backup"]
            if backup.exists():
                write_atomic(source, read_text(backup), source)
        raise

    print(f"Disabled {len(selected)} PPA entr{'y' if len(selected) == 1 else 'ies'}.")
    print(f"Backup: {backup_dir}")
    return backup_dir


def run_full_update(apt_get: str) -> int:
    print("Running final apt-get update...")
    env = os.environ.copy()
    env.update({"LC_ALL": "C", "LANG": "C", "DEBIAN_FRONTEND": "noninteractive"})
    proc = subprocess.run([apt_get, "update"], env=env, check=False)
    return proc.returncode


def write_json_report(path: Path, results: Sequence[CheckResult]) -> None:
    payload = {
        "version": VERSION,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "results": [
            {
                "label": result.candidate.label,
                "path": str(result.candidate.path),
                "format": result.candidate.fmt,
                "location": result.candidate.location,
                "status": result.status,
                "attempts": result.attempts,
                "return_codes": result.return_codes,
                "summary": result.summary,
            }
            for result in results
        ],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def list_backups(backup_root: Path) -> List[Path]:
    if not backup_root.is_dir():
        return []
    return sorted(
        [path for path in backup_root.iterdir() if path.is_dir() and (path / "manifest.json").is_file()],
        reverse=True,
    )


def show_backups(backup_root: Path) -> int:
    backups = list_backups(backup_root)
    if not backups:
        print("No backups found.")
        return 0
    for path in backups:
        try:
            manifest = json.loads((path / "manifest.json").read_text(encoding="utf-8"))
            count = len(manifest.get("disabled", []))
            created = manifest.get("created_at", "unknown")
            policy = manifest.get("policy", "unknown")
            print(f"{path.name}  entries={count}  policy={policy}  created={created}")
        except (OSError, json.JSONDecodeError):
            print(f"{path.name}  INVALID MANIFEST")
    return 0


def resolve_backup(backup_root: Path, backup_id: str) -> Path:
    if backup_id == "latest":
        backups = list_backups(backup_root)
        if not backups:
            raise CleanerError("No backups found.")
        return backups[0]
    candidate = backup_root / backup_id
    if not (candidate / "manifest.json").is_file():
        raise CleanerError(f"Backup not found: {candidate}")
    return candidate


def restore_backup(backup_root: Path, backup_id: str, apply: bool, force: bool) -> int:
    backup_dir = resolve_backup(backup_root, backup_id)
    manifest = json.loads((backup_dir / "manifest.json").read_text(encoding="utf-8"))
    files = manifest.get("files", [])
    print(f"Backup: {backup_dir}")
    for item in files:
        print(f"RESTORE  {item['source']}  <-  {item['backup']}")
    if not apply:
        print("Dry-run only. Add --apply to restore these files.")
        return 0
    if not is_root():
        raise CleanerError("Restoring requires root. Re-run with sudo.")

    for item in files:
        source = Path(item["source"])
        backup = backup_dir / item["backup"]
        if not source.exists():
            raise CleanerError(f"Current source file is missing: {source}")
        if not backup.is_file():
            raise CleanerError(f"Backup file is missing: {backup}")
        current_hash = sha256_file(source)
        expected_after = item.get("sha256_after")
        if expected_after and current_hash != expected_after and not force:
            raise CleanerError(
                f"Refusing to overwrite changed file {source}. Use --force only after reviewing it."
            )

    for item in files:
        source = Path(item["source"])
        backup = backup_dir / item["backup"]
        write_atomic(source, read_text(backup), source)
    print(f"Restored {len(files)} file{'s' if len(files) != 1 else ''}.")
    return 0


def add_common_check_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--sources-root", type=Path, default=Path("/etc/apt"), help="APT configuration root (default: /etc/apt)")
    parser.add_argument("--host-regex", default=DEFAULT_HOST_REGEX, help="Regex selecting repository hosts")
    parser.add_argument("--apt-get", default="/usr/bin/apt-get", help="apt-get executable")
    parser.add_argument("--timeout", type=int, default=15, help="APT HTTP/HTTPS timeout per request")
    parser.add_argument("--attempts", type=int, default=2, help="Checks per source; any success marks it healthy")
    parser.add_argument("--jobs", type=int, default=4, help="Parallel source checks")
    parser.add_argument("--json-report", type=Path, help="Write machine-readable results")
    parser.add_argument("--verbose", action="store_true", help="Show complete apt output")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Safely detect and disable broken Ubuntu Launchpad PPAs.")
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="Test matching active PPAs without changing files")
    add_common_check_args(check)

    clean = sub.add_parser("clean", help="Test PPAs and optionally disable failures")
    add_common_check_args(clean)
    clean.add_argument("--policy", choices=sorted(DISABLE_BY_POLICY), default="dead", help="dead: missing repo only; broken: dead plus signature/config errors; all: every failure")
    clean.add_argument("--apply", action="store_true", help="Actually edit source files; otherwise dry-run")
    clean.add_argument("--backup-root", type=Path, default=Path("/var/backups/ppa-cleaner"), help="Backup directory")
    clean.add_argument("--no-final-update", action="store_true", help="Do not run a full apt-get update after applying")

    backups = sub.add_parser("backups", help="List available cleanup backups")
    backups.add_argument("--backup-root", type=Path, default=Path("/var/backups/ppa-cleaner"))

    restore = sub.add_parser("restore", help="Restore source files from a cleanup backup")
    restore.add_argument("backup_id", nargs="?", default="latest", help="Backup directory name or 'latest'")
    restore.add_argument("--backup-root", type=Path, default=Path("/var/backups/ppa-cleaner"))
    restore.add_argument("--apply", action="store_true", help="Actually restore; otherwise dry-run")
    restore.add_argument("--force", action="store_true", help="Overwrite source files changed since cleanup")

    return parser


def validate_positive(name: str, value: int) -> None:
    if value < 1:
        raise CleanerError(f"{name} must be at least 1")


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "backups":
            return show_backups(args.backup_root)
        if args.command == "restore":
            return restore_backup(args.backup_root, args.backup_id, args.apply, args.force)

        validate_positive("--timeout", args.timeout)
        validate_positive("--attempts", args.attempts)
        validate_positive("--jobs", args.jobs)
        candidates = scan_candidates(args.sources_root, args.host_regex)
        results = run_checks(candidates, args.apt_get, args.timeout, args.attempts, args.jobs)
        print_results(results, args.verbose)
        if args.json_report:
            write_json_report(args.json_report, results)
            print(f"JSON report: {args.json_report}")

        if args.command == "check":
            return 1 if any(result.status != "ok" for result in results) else 0

        selected = [result for result in results if result.status in DISABLE_BY_POLICY[args.policy]]
        if not args.apply:
            print(
                f"Dry-run: {len(selected)} entr{'y' if len(selected) == 1 else 'ies'} would be disabled "
                f"under policy '{args.policy}'. Add --apply to proceed."
            )
            return 1 if selected else 0

        backup = apply_cleanup(results, args.policy, args.sources_root, args.backup_root)
        if backup and not args.no_final_update:
            return run_full_update(args.apt_get)
        return 0
    except CleanerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
