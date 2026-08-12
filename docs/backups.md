# Backups: proving a restore, not hoping for one

## The shape

Two independent restic repositories. Not a mirror.

| Copy | Where | When | Purpose |
|---|---|---|---|
| Local | USB SSD, always plugged in | 05:30, and chained after every cloud run | restore in minutes |
| Offsite | Backblaze B2 | 03:30 | survive fire, theft, flood |

The same password opens both. It lives in an encrypted recovery kit stored outside the
house, and nowhere else that matters.

## Why not a mirror

`restic copy` from cloud to disk is cheaper: one read, two destinations. It is also a single
history with two locations. A mistaken `forget` on the source propagates on the next sync,
and the second copy quietly stops being a second copy.

Two repositories cost a second read of 17 GB per day. At 33 seconds for the local run, that
is a price worth paying for the failure mode it removes.

## The guards that matter

**The mount check.** The local script refuses to run if `/mnt/backup` is not mounted. Without
it, a disconnected disk means restic writes into the empty mount point, which is the system
NVMe, filling the boot drive silently. This is the single most valuable line in the script.

```bash
mountpoint -q "$MOUNT" || { write_state false "backup disk not mounted"; exit 1; }
```

**Mount by UUID with `nofail`.** The server boots even when the disk is dead or absent.
A backup disk must never be able to prevent the machine from starting.

**USB autosuspend disabled.** Otherwise the disk sleeps mid-run and restic collects I/O
errors on a backup that looked healthy when it started.

**A skip window, not a duplicate.** The local copy is chained to the cloud run on success, so
one button does both. Its own timer then becomes a safety net: it skips if a successful run
happened in the last 6 hours, but never skips after a failure.

## Proving it

Backups that have never been restored are hopes. Two mechanisms turn hope into evidence:

**Monthly restore drill.** Restores real files to a scratch location and records whether it
worked, how many files came back, and when. The dashboard shows the result and turns it red
when it goes stale past 40 days.

**Weekly integrity check.** `restic check --read-data-subset=5%` on the local repository.
Cheap USB enclosures lie about writes; this reads a random slice back and verifies it.

```
check snapshots, trees and blobs
[0:00] 100.00%  1 / 1 snapshots
read 5.0% of data packs
[0:01] 100.00%  45 / 45 packs
no errors were found
```

## The runbook was broken, and only a rehearsal found it

The disaster recovery script was written when backups went to a different provider through
`rclone`. After migrating to B2 with restic's native backend, the script still demanded
`rclone.conf` and an environment file that no longer existed, and aborted on its first check.

Nothing detected this. The backups ran fine. The drill passed, because the drill proves the
*data* restores, not that the *runbook* works. The failure would have surfaced with a dead
server and no patience left.

The rehearsal that found it: a fake server with the same shape as the real one, a real restic
repository, files deleted, the guide followed exactly on a clean Ubuntu image. Every file came
back with its content intact. Two rounds of fixes came out of it, including a path-extraction
bug that fed restic a "path" called `===` scraped out of an echo line.

The current restore script takes its paths from **the latest snapshot in the repository**
rather than parsing another script, filters anything that is not an existing absolute path,
and validates the script it generates with `bash -n` before installing it. Validating the
generator was not enough: the artefact is what runs.

## What the operator sees

The dashboard reads a state file written by the backup script and shows both copies, with the
age of the last run, snapshot count and free space. If the local copy goes 48 hours without
running, or the disk disappears, the healthy green bar becomes a warning.

Nothing is shown for a copy that does not exist. A dashboard that promises a backup it does
not have is worse than one that says nothing.
