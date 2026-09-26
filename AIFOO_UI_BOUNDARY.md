# Sub2API Custom Full-Stack Boundary

This branch is the maintained full-stack fork. It owns the AIFoo frontend and
the forked Sub2API backend that serves it.

## Runtime ownership

- `production` keeps the official `weishaw/sub2api` backend and the separate AIFoo UI deployment. This branch does not change that boundary.
- `sub2api-custom` builds one full-stack image from the branch: the new backend and the compiled AIFoo frontend are shipped together.
- The branch-owned deployment files, update bridge, deploy helper, image repository, and release workflow all target the custom full-stack artifact.

## Backend updates

The version panel checks releases from `JayHome137/sub2api`. Its three Docker mutations are routed to the VPS-local bridge:

1. Update or rollback pulls the selected custom full-stack image and records its exact digest.
2. The restart confirmation activates only the prepared custom `sub2api` image.
3. Health and binary-version checks must pass; otherwise the previous Compose file and image are restored.

The custom branch release workflow builds and publishes the full-stack image and binary assets. The runtime update path consumes only the published immutable artifact; it does not build on the production host.

## UI updates

The AIFoo UI is preserved as the visual base, while branch backend changes and their required UI/API compatibility fixes are maintained together. A push to `sub2api-custom` produces a full-stack release after validation.

The V3 channel-monitor presentation is part of this retained frontend. It uses
the official V2 snapshot/matrix APIs and the existing V2 monitoring mode; no
fork-specific backend or database migration is required. `/monitor?monitor_view=v2`
keeps the previous V2 presentation available for diagnosis. Preserve the V3
components, locales, layout/format helpers, and view selection during upstream
syncs; check API compatibility rather than overwriting the frontend. The initial
presentation was ported from kiss-kedaya/sub2api commit
`25f896f712ce99745decba6f817e794e1fb8e00d`.

`production` has no scheduled, push, pull-request, release, or Issue workflows;
its existing AIFoo UI workflow remains manual-only. `sub2api-custom` has one
push/manual release workflow for the full-stack image and release assets. The VM
remains available only for deliberate AIFoo UI work on `production`.
