# V3 local test baseline

This is an isolated test deployment, not the production deployment configuration.
The backend starts at official `weishaw/sub2api:0.2.4`. V3 belongs to the AIFoo
frontend and continues to use the official V2 monitoring APIs.

The test machine's deployment directory is `~/aifoo-v3-test`. Its `.env` contains
new test-only credentials. `ADMIN_PASSWORD` is shared by these disposable test
logins:

- `admin@v3-test.invalid`: administrator; first-login compliance acknowledgement
  is deliberately left for the operator.
- `viewer@v3-test.invalid`: viewer of the imported monitoring groups.
- `restricted@v3-test.invalid`: viewer restricted to one test group.

The frontend is served on port 18083; the backend's port 18084 is loopback-only.
PostgreSQL and Redis have no host-published ports. The test deployment does not
share production volumes or the test machine's other application containers.

## Deployment inputs

`Dockerfile` packages the already validated `backend/internal/web/dist` output
with the existing AIFoo landing pages and Nginx configuration. `compose.yml`
expects a locally rendered `nginx.conf` in the deployment directory: it preserves
`deploy/frontend/nginx.conf` and adds the three exact upgrade locations from
`deploy/update-bridge/nginx-location.conf`, pointing at the test bridge.

The existing update bridge and restricted deploy helper were built without
source changes. The test-specific systemd service is `aifoo-v3-test-bridge`;
its helper is configured exclusively for this Compose project and its containers.
It listens on the test Docker network gateway, authenticates against the
loopback test backend, and uses a separate state/lock directory. Its installed
configuration is recorded on the test host, not copied from production secrets.

## Imported data

Only group identity/display fields, monitoring configuration/watermarks,
recent two-hour aggregates, and fixed 24h/7d/30d aggregate buckets were copied.
Latency histograms use only aggregate `user_id = 0` rows. The configuration's
production administrator reference was cleared. No production users, account
credentials, API keys, payment settings, raw usage logs, or raw error bodies
were imported. Test viewers were created separately.

These are historical snapshots, not a live production feed. Without test
traffic the recent time window ages, and official aggregation can replace
recent buckets with empty results. Use the longer ranges for historical
comparison. Empty or insufficient samples are not evidence of upgrade failure.

The remote `monitor-snapshot.sql` and `monitor-recent.sql` files retain the
minimal import. `baseline-0.2.4.dump` is the test database's recovery checkpoint;
`baseline-frontend-image.txt` and `baseline-frontend-entry.sha256` identify the
unchanged frontend for the operator's later upgrade comparison.

## Verified before handoff

- 45 targeted tests passed across 11 files; frontend typecheck, changed-component
  ESLint and production build passed.
- Official backend 0.2.4 ran with the custom frontend and imported aggregates.
- Live matrix APIs returned data for 90m, 24h, 7d and 30d.
- Full viewer saw five configured groups; restricted viewer saw one authorized
  group across all four ranges.
- Non-administrators were denied access to update and restart operations.
- Real browser login, V3 cards, mobile layout and V2 fallback were checked.
- Screenshots and browser results are retained locally under
  `frontend/test-results/v3-baseline/` as final evidence.

## Operator upgrade test

No backend upgrade was performed. Log in as the test administrator and review
the initial acknowledgement. Use the existing version panel to select/update
the backend and confirm its restart when ready. The normal update button follows
the current official release; inspect the target version before confirming.

After upgrading, verify the reported backend version, the four V3 ranges,
restricted viewer scope and `/monitor?monitor_view=v2`. Compare the frontend
container image and `app.html` hash to the saved baseline: they should be
unchanged. Actual post-upgrade compatibility remains unverified until this test.
