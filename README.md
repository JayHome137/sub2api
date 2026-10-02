<div align="center">

<img src="assets/logo.svg" alt="Sub2API Logo" width="128" />

# Sub2API

[![Go](https://img.shields.io/badge/Go-1.27.0-00ADD8.svg)](https://golang.org/)
[![Vue](https://img.shields.io/badge/Vue-3.4+-4FC08D.svg)](https://vuejs.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-336791.svg)](https://www.postgresql.org/)
[![Redis](https://img.shields.io/badge/Redis-7+-DC382D.svg)](https://redis.io/)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED.svg)](https://www.docker.com/)

<a href="https://trendshift.io/repositories/21823" target="_blank"><img src="https://trendshift.io/api/badge/repositories/21823" alt="Wei-Shaw%2Fsub2api | Trendshift" width="250" height="55"/></a>

**AI API Gateway Platform for Subscription Quota Distribution**

English | [中文](README_CN.md)

</div>

## About this fork

This repository is a customized full-stack fork of [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api). It keeps the upstream gateway foundation, adds the AIFOO interface, and publishes releases from this repository.

For the upstream project's general features and documentation, see [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api).

## Custom features

- V3 channel monitoring with scheduled connectivity and quality checks, including Pelican SVG review and answer-matching candy questions.
- Per-account control for automatic pause after repeated degradation results, with group-capacity protection.
- Full-stack releases that bundle the AIFOO interface and backend. The built-in updater uses this repository's GitHub Releases and GHCR images.

## Releases and deployment

- [GitHub Releases](https://github.com/JayHome137/sub2api/releases) provide Linux amd64 binaries, the update control-plane bundle, and versioned full-stack container images.
- For a standalone binary installation, use this repository's installer:

  ```bash
  curl -sSL https://raw.githubusercontent.com/JayHome137/sub2api/sub2api-custom/deploy/install.sh | sudo bash
  ```

- Existing full-stack deployments can use the admin update panel after installing the matching update control plane. See the [update guide](deploy/update-bridge/README.md).
- Docker Compose templates are in [`deploy/`](deploy/). Set `SUB2API_IMAGE` and `SUB2API_QUALITY_RENDERER_IMAGE` to the same release version; the templates' default tags may lag behind.

The installation script and releases belong to `JayHome137/sub2api`; upstream releases are not used by this fork's updater.

## License

Licensed under [LGPL-3.0-or-later](LICENSE). Original project copyright: Wesley Liddick, 2026.
