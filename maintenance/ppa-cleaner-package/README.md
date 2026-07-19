# ppa-cleaner

A conservative, standard-library-only Python utility for routinely finding and disabling Ubuntu Launchpad PPAs that no longer work.

## Safety model

- **Dry-run by default.** Source files change only when `--apply` is supplied.
- Tests each PPA independently, avoiding ambiguous output from a global `apt update`.
- Supports classic `/etc/apt/sources.list` and `*.list` entries.
- Supports deb822 `*.sources` stanzas and disables them with `Enabled: no`.
- Retries each source; any successful attempt marks the source healthy.
- Does not disable temporary DNS, timeout, TLS, or network failures under the default policy.
- Creates a timestamped backup and JSON manifest before editing.
- Uses atomic file replacement and refuses to edit a file that changed after scanning.
- Includes dry-run restore and changed-file protection.
- Does not uninstall or downgrade packages already installed from a PPA; it only disables the APT source.

## Requirements

- Ubuntu with Python 3.8 or newer
- `apt-get`
- Root only when applying or restoring changes
- No third-party Python packages

## Install

```bash
chmod +x install.sh
sudo ./install.sh
```

Install and enable the weekly timer immediately:

```bash
sudo ./install.sh --enable-timer
```

## Manual use

Check active Launchpad PPAs without changing anything:

```bash
sudo ppa-cleaner check
```

Preview what the safe default policy would disable:

```bash
sudo ppa-cleaner clean
```

Disable only PPAs that are clearly gone, such as a `404`, `410`, or missing Release file:

```bash
sudo ppa-cleaner clean --apply
```

Also disable persistent GPG, authentication, malformed-entry, or Signed-By failures:

```bash
sudo ppa-cleaner clean --apply --policy broken
```

Disable every failed check, including transient and unknown failures. This is intentionally not recommended for unattended use:

```bash
sudo ppa-cleaner clean --apply --policy all
```

Increase certainty before unattended cleanup:

```bash
sudo ppa-cleaner clean \
  --apply \
  --policy dead \
  --attempts 3 \
  --timeout 20 \
  --jobs 4
```

Write a machine-readable report:

```bash
sudo ppa-cleaner check --json-report /tmp/ppa-report.json
```

## Policies

| Policy | Automatically disables |
|---|---|
| `dead` | `404`, `410`, missing/no-longer-present Release file |
| `broken` | Everything in `dead`, plus persistent signature, key, auth, malformed source, and Signed-By errors |
| `all` | Every failed result, including transient network and unknown errors |

The default is `dead`.

## Backups and restore

Backups are stored under `/var/backups/ppa-cleaner/<UTC timestamp>/`.

List backups:

```bash
sudo ppa-cleaner backups
```

Preview restoration of the latest backup:

```bash
sudo ppa-cleaner restore latest
```

Restore it:

```bash
sudo ppa-cleaner restore latest --apply
```

Restore a named backup:

```bash
sudo ppa-cleaner restore 20260719T112915Z --apply
```

The restore command refuses to overwrite a source file changed since cleanup. Review the file before using `--force`.

## Routine scheduling

The included timer runs weekly on Sunday at 04:15, with up to 30 minutes of randomized delay:

```bash
sudo systemctl enable --now ppa-cleaner.timer
systemctl list-timers ppa-cleaner.timer
```

Run the service immediately:

```bash
sudo systemctl start ppa-cleaner.service
journalctl -u ppa-cleaner.service --no-pager
```

Change the cadence by editing `/etc/systemd/system/ppa-cleaner.timer`, then run:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ppa-cleaner.timer
```

For an unattended machine, keep `--policy dead`. Change the service command only when you intentionally want broader cleanup.

## Configuration options

```text
--sources-root PATH   APT configuration root; default /etc/apt
--host-regex REGEX    Select repository hosts; defaults to Launchpad PPA hosts
--apt-get PATH        apt-get executable
--timeout SECONDS     HTTP/HTTPS request timeout; default 15
--attempts NUMBER     Checks per source; default 2
--jobs NUMBER         Parallel checks; default 4
--json-report PATH    Write JSON results
--verbose             Print complete apt output
```

Cleanup-only options:

```text
--policy dead|broken|all
--apply
--backup-root PATH
--no-final-update
```

The host matcher makes the utility adaptable to other third-party repositories. Preview carefully before applying:

```bash
sudo ppa-cleaner check \
  --host-regex '(download\.docker\.com|packages\.microsoft\.com)'
```

## Exit codes

- `0`: successful check with no failures, successful cleanup, or successful restore
- `1`: check found failures, dry-run found entries eligible for cleanup, or final `apt-get update` failed
- `2`: invalid input, unsafe file state, missing executable, permissions, or another controlled error
- `130`: interrupted

## Uninstall

```bash
sudo systemctl disable --now ppa-cleaner.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/ppa-cleaner.{service,timer}
sudo rm -f /usr/local/sbin/ppa-cleaner
sudo rm -rf /usr/local/share/doc/ppa-cleaner
sudo systemctl daemon-reload
```

Backups under `/var/backups/ppa-cleaner` are deliberately retained.
