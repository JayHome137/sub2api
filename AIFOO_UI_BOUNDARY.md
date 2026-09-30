# AIFoo UI Boundary

This private repository maintains the AIFoo frontend inside the versioned full-stack release.

## Runtime ownership

- The production app runs `ghcr.io/jayhome137/sub2api` at an immutable digest.
- The release workflow builds the backend and embeds the AIFoo frontend into the same image and Linux binary.
- The local update bridge and restricted deploy helper are versioned control-plane assets published with each release.
- `deploy/frontend/` is retained only for historical V3 test fixtures; it is not a production deployment path.

## Backend updates

The version panel still checks releases and lists rollback versions through the application API. Its three Docker mutations are routed to the VPS-local bridge:

1. Update or rollback pulls the selected self-owned full-stack image and records its exact digest.
2. The restart confirmation activates only the prepared app service image.
3. Health and binary-version checks must pass; otherwise the previous Compose file and image are restored.

The production host does not build source or mount a working checkout. It consumes the published Release and GHCR image only.

## UI updates

The AIFoo UI stays fixed until it is intentionally changed. A new upstream backend release alone is not a UI rebuild trigger. When upstream adds a user-visible route, API contract, or page that AIFoo needs, compatibility is handled on a feature branch and published through the full-stack release workflow. There is no separate frontend image or frontend-only production deployment.

The V3 channel-monitor presentation is part of this retained frontend. It uses
the official V2 snapshot/matrix APIs and the existing V2 monitoring mode; no
fork-specific backend or database migration is required. `/monitor?monitor_view=v2`
keeps the previous V2 presentation available for diagnosis. Preserve the V3
components, locales, layout/format helpers, and view selection during upstream
syncs; check API compatibility rather than overwriting the frontend. The initial
presentation was ported from kiss-kedaya/sub2api commit
`25f896f712ce99745decba6f817e794e1fb8e00d`.

The `sub2api-custom-upstream` branch is the official upstream baseline. The
upstream sync workflow runs daily at 00:30 Singapore time and can also be
started manually. It updates that baseline to the latest upstream release,
creates an integration branch from `sub2api-custom`, resolves textual
conflicts in favor of the custom branch, and opens or updates a PR targeting
`sub2api-custom`. The PR validation workflow must pass before the PR is merged.

The custom release workflow runs validation on the PR and after a merge to
`sub2api-custom`; after a successful merge it publishes the matching upstream
version tag without a `custom` prefix, together with the matching Linux
control-plane package. The test host remains available for deliberate
validation before production rollout.
