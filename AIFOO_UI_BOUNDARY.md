# AIFoo UI Project Boundary

## Purpose

This fork exists to embed the AIFoo interface directly into the Sub2API
frontend source. The result must build and load as one frontend application;
it must not depend on a runtime overlay or a second UI layer.

## Upstream Alignment Rule

The official upstream update behavior is the default contract. Do not add an
update, backup, migration, rollback, deployment, or safety step unless it
exists in the official upstream flow or the user explicitly requests it.

The only approved fork-specific update-flow differences are:

- Merge each official stable release into the source-integrated AIFoo UI.
- Keep GitHub Actions workflows fork-owned during automated release merges;
  record upstream workflow differences for separate review.
- Complete the requested validation and image preparation before showing the
  update prompt.
- Show the update state in the existing web UI and dispatch the approved
  production switch from that button.

These four differences are mandatory because they are the reason this fork
exists. Upstream alignment must not remove or bypass them.

Successful validation evidence may be reused across a replacement PR when the
relevant code, inputs, conditions, environment, base, workflow contract, and
candidate content are unchanged. Re-run only failed, skipped, not-yet-run, or
downstream checks affected by the fix; a new PR number alone is not a reason to
repeat a successful check.

These differences must not introduce database dumps, backup identifiers,
backup-only gates, database restore automation, or repeated validation after
the update button is clicked. If an older rule conflicts with this section,
this section wins and the smallest conforming change must be used.

## In Scope

- AIFoo UI source under `frontend/src` and its frontend assets.
- Merging official stable Sub2API releases into the fork.
- Resolving upstream conflicts that affect the embedded UI or its API contract.
- Frontend lint, type checks, build, focused browser checks, and the private
  frontend image.
- Separate, manually approved activation of the prepared update.

## Out Of Scope By Default

- Runtime UI overrides, iframe-based replacement, DOM overlays, or duplicate
  logo injection.
- Independent backend features, billing changes, provider behavior, account
  management, or database changes unrelated to an upstream UI contract.
- A second frontend/backend version synchronization system.
- Editing `backend/cmd/server/VERSION` or `frontend/package.json` only to make
  a release number look aligned.
- Deploying to the VPS from a scheduled upstream check.
- Repeating broad builds or full workflows when a focused check proves the
  changed surface.

## Version Rule

The backend release and its source version files remain upstream-owned. The
visible UI version comes from the running backend APIs:

- `/api/v1/settings/public`
- `/admin/system/check-updates`

Never change a version file solely to match a tag. A release is accepted only
when the official release commit and official immutable image are verified.

## Change Gate

Before accepting a change, answer these questions:

1. Does it directly support the source-integrated AIFoo UI?
2. Does it touch only the frontend, the frontend image, or an upstream API
   contract that the UI actually consumes?
3. Can a focused frontend check prove the behavior?

If the answer to the first question is no, the change needs an explicit
explanation and approval before implementation. A backend change is included
only when it comes from the official upstream release or is required to keep
an existing UI contract working.

## Release Flow

1. Detect an official stable upstream release.
2. Merge the exact upstream release commit into a candidate branch.
3. Preserve the complete fork-owned `.github/workflows` tree and record any
   official workflow additions, changes, or deletions for separate review.
4. Resolve every remaining merge conflict deterministically: keep the
   fork-owned UI and delivery contract, take official upstream hunks elsewhere,
   and continue to validation. Only an unresolved conflict or a failed
   validation check stops the candidate.
5. Run focused frontend validation and build the private frontend image.
6. Record the result and expose the web update only after preparation; do not
   switch production automatically.
7. Activate the prepared update on the VPS only after explicit approval.

This boundary is the default for future work. Requirements that exceed it
must be called out before code or infrastructure changes begin.
