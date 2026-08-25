# AIFoo UI Boundary

This private repository has one maintained fork boundary: the AIFoo frontend.

## Runtime ownership

- The production backend runs the official `weishaw/sub2api` image at an immutable digest.
- Backend releases are not merged, rebuilt, or republished by this repository.
- The checked-in backend and standard deployment files remain an unmodified snapshot of the official stable release for reference.
- AIFoo owns `frontend/`, `deploy/frontend/`, the local update bridge, the restricted deploy helper, and the single manual UI workflow.

## Backend updates

The official version panel still checks releases and lists rollback versions through the official backend API. Its three Docker mutations are routed to the VPS-local bridge:

1. Update or rollback pulls the selected official image and records its exact digest.
2. The official restart confirmation activates only the prepared `sub2api` image.
3. Health and binary-version checks must pass; otherwise the previous Compose file and image are restored.

This path does not use GitHub Actions, the self-hosted VM, private-repository Issues, pull requests, labels, or artifacts.

## UI updates

The AIFoo UI stays fixed until it is intentionally changed. A new upstream backend release alone is not a UI rebuild trigger. When upstream adds a user-visible route, API contract, or page that AIFoo needs, compatibility is handled manually and the `AIFoo UI` workflow is dispatched once for VM validation, image publication, and optional frontend-only deployment.

There are no scheduled, push, pull-request, release, or Issue workflows. The VM remains available only for deliberate AIFoo UI work.
