# scripts

Real scripts from the lab, not sketches. Each one is idempotent and safe to run twice.

## setup-local-backup.sh

Adds a **second backup copy on a USB SSD** to a machine that already backs up offsite with
restic, and wires its result into the dashboard so a stale local copy is visible instead of
assumed.

It refuses to guess. It reads the existing backup script to find the repository password and the
paths already being backed up, so the local copy covers exactly what the offsite copy covers. If
it cannot find them it says so and stops, rather than backing up the wrong thing quietly.

What it installs:

- a `homelab-backup-local.service`, chained from the offsite backup with `OnSuccess=`, so the
  local copy only runs after the remote one succeeded
- a check timer that writes `local-backup.json` (age, free space, snapshot count) for the
  dashboard to read
- retention with `restic forget --prune`

Run it with `sudo bash setup-local-backup.sh`. Set `FALLBACK_PATHS` if the machine's layout is
not the one it infers.

Why a second copy at all: the offsite copy protects against the house burning down, and the
local one protects against the offsite provider being slow or unreachable, which is not
hypothetical. A restic backup to a cloud remote once hung here for two and a half days holding
the repository lock, which also made the monthly restore drill fail.
