# qlever-plazi

The SPARQL endpoint https://qlever.ld.plazi.org/sparql serves Plazi's treatments and the Catalogue of Life (CoL) using [QLever](https://github.com/ad-freiburg/qlever).

- **Treatments**: the N-Quads export of [turtle-hook-nq](https://github.com/plazi/turtle-hook-nq) (`https://hooknq.ld.plazi.org/nquads`), with one named graph per treatment.
- **CoL**: the latest release of [catologueoflife-to-rdf](https://github.com/plazi/catologueoflife-to-rdf), in the default graph. `<https://www.catalogueoflife.org/data> owl:versionInfo` holds the CoL version.

## Nightly build

`scripts/qlever-plazi.sh run` runs every night at 02:14 on the QLever host, as the system user `qlever-plazi`, from a systemd timer (`systemd/`). It uses the upstream `adfreiburg/qlever` image unchanged:

```
/opt/qlever-plazi/                 this repository; each run first pulls main, so a merge deploys with the next run
/fastssd/qlever-plazi/             the data (QP_ROOT)
  indexes/2026-09-25T02-14-03Z_8eab036_col-2026-08-26/   one directory per index, never modified once built
  current -> indexes/...           the index being served
  public/status/                   served at https://qlever.ld.plazi.org/status/
```

### Setup

Once, as root, from a checkout of this repository:

```bash
sudo ./systemd/install.sh
```

It creates the user and both directories, clones the repository to `/opt/qlever-plazi`, installs and enables the timer, and runs the first build (about 30 minutes). It also takes over from the earlier setup, which ran from the crontab of `reto` with its data in `~reto/qlever-plazi-data`. The first build drains that server, and the old data is removed once nothing serves it any more. The script is safe to run again.

The timer catches up on a run missed while the host was down (`Persistent=true`). Run logs go to the journal as well as to the status page:

```bash
systemctl list-timers qlever-plazi.timer   # last and next run
systemctl start qlever-plazi               # run now
journalctl -u qlever-plazi                 # logs
```

A run takes these steps:

1. **Gate.** It reads the `till` of the newest completed job from `hooknq.ld.plazi.org/jobs.json?from=0&till=2` and the latest CoL release tag. If both match `current/stamp.json`, it logs `skipped — no change` and stops.
2. **Disk space.** The build needs about 35 GB while it runs, and `/fastssd` is shared with other services. With less than 50 GB free (`QP_MIN_FREE_GB`), the run fails before downloading anything.
3. **Download and verify.** The treatments export has to end with `# END till=<commit> lines=<n> sha256=<hex>`, and the line count and hash of everything before that line have to match. Otherwise the run stops before indexing.

   This check is essential. The HTTP status is sent before the export runs, so a truncated export still arrives as a successful 200. Between 2026-09-13 and 2026-09-25 that is how the endpoint ended up serving 318k of 891k treatments: the export was cut off after 2^24 triples.
4. **Index** into a new directory named after the build time, the hooknq commit and the CoL version.
5. **Check.** The run starts a server on the new index, not yet reachable from outside, and requires all of these:
   - at least 98% of the treatments currently live (`QP_MIN_RATIO`);
   - the CoL `owl:versionInfo` equals the version in the downloaded `col.nt`;
   - the kingdoms canary (`SELECT DISTINCT ?kingdom { ?taxon dwc:kingdom ?kingdom }`) returns `Plantae`;
   - `<https://treatment.plazi.org/id/03DC6055C158FFEB52E2CC860DA3FB8F>` has triples (Plazi IRIs are `https://` since plazi/gg2rdf#33).

   If any check fails, the run fails and the live index keeps serving.
6. **Go live.** Once the checks pass, the new server's Docker health check turns healthy and Traefik starts routing to it. Then the `current` symlink is swapped atomically (`ln -sfn … current.new && mv -Tf current.new current`) and the previous server is stopped. The endpoint keeps serving throughout.
7. **Prune.** The three newest indexes are kept for rollback (`QP_KEEP`), plus the live one in any case.

Every run writes these files under `https://qlever.ld.plazi.org/status/`:

| File | Content |
|---|---|
| `logs/<run>.txt` | the full log of the run |
| `runs.json` | recent runs, newest first |
| `status.json` | the live index stamp (with `built_at`) and its treatment count next to LINDAS |
| `status.svg` | a badge showing the treatment count, the percentage of LINDAS and the build date |
| `health` | present (HTTP 200) only if the last run did not fail and the live count is at least 98% of LINDAS; otherwise 404. Monitor this file, e.g. from Upptime. |

### Operations

```bash
sudo -u qlever-plazi /opt/qlever-plazi/scripts/qlever-plazi.sh list            # kept indexes, * = live
sudo -u qlever-plazi /opt/qlever-plazi/scripts/qlever-plazi.sh rollback NAME   # serve an earlier index again
sudo -u qlever-plazi env QP_FORCE=1 /opt/qlever-plazi/scripts/qlever-plazi.sh run  # build even if nothing changed
```

The variables at the top of `scripts/qlever-plazi.sh` configure the paths, the Docker network, the Traefik router and the thresholds.

To run a test setup next to the live one, change at least `QP_ROOT`, `QP_PREFIX`, `QP_ROUTER` and `QP_HOST`, and set `QP_LEGACY_CONTAINER=`. Otherwise a test run would take over the live router or stop the live containers.

### Access token

Nothing here needs QLever's privileged operations. Each server gets a random access token when it starts, and the token never leaves the container. `qlever start` needs a token only to set the index description.
