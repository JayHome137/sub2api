# AIFoo UI Project Boundary

## Purpose

This fork exists to embed the AIFoo interface directly into the Sub2API
frontend source. The result must build and load as one frontend application;
it must not depend on a runtime overlay or a second UI layer.

## In Scope

- AIFoo UI source under `frontend/src` and its frontend assets.
- Merging official stable Sub2API releases into the fork.
- Resolving upstream conflicts that affect the embedded UI or its API contract.
- Frontend lint, type checks, build, focused browser checks, and the private
  frontend image.
- Separate, manually approved frontend deployment with backup and rollback.

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
3. Resolve only UI or UI-contract conflicts.
4. Run focused frontend validation and build the private frontend image.
5. Record the result for review; do not deploy automatically.
6. Deploy to the VPS only after explicit approval, with backup and rollback.

This boundary is the default for future work. Requirements that exceed it
must be called out before code or infrastructure changes begin.
