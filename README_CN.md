<div align="center">

<img src="assets/logo.svg" alt="Sub2API Logo" width="128" />

# Sub2API

[![Go](https://img.shields.io/badge/Go-1.27.0-00ADD8.svg)](https://golang.org/)
[![Vue](https://img.shields.io/badge/Vue-3.4+-4FC08D.svg)](https://vuejs.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-336791.svg)](https://www.postgresql.org/)
[![Redis](https://img.shields.io/badge/Redis-7+-DC382D.svg)](https://redis.io/)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED.svg)](https://www.docker.com/)

<a href="https://trendshift.io/repositories/21823" target="_blank"><img src="https://trendshift.io/api/badge/repositories/21823" alt="Wei-Shaw%2Fsub2api | Trendshift" width="250" height="55"/></a>

**AI API 网关平台 - 订阅配额分发管理**

[English](README.md) | 中文 | [日本語](README_JA.md)

</div>

## 关于本仓库

本仓库是基于 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api) 的全栈定制分支，保留上游网关基础能力，集成 AIFOO 界面，并由本仓库构建和发布版本。

上游通用功能和完整文档请见 [Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api)。

## 定制功能

- V3 渠道监控：按计划执行连通性与质量检测，支持鹈鹕 SVG 评审和糖果题答案匹配。
- 账号级自动暂停控制：连续检测结果降级后可自动暂停，并遵守分组可用账号保护。
- 全栈 Release：后端与 AIFOO 界面一并发布；内置更新器使用本仓库的 GitHub Release 和 GHCR 镜像。

## Release 与部署

- [GitHub Releases](https://github.com/JayHome137/sub2api/releases) 提供 Linux amd64 二进制、更新控制面安装包和带版本号的全栈容器镜像。
- 独立二进制安装可使用本仓库的安装脚本：

  ```bash
  curl -sSL https://raw.githubusercontent.com/JayHome137/sub2api/sub2api-custom/deploy/install.sh | sudo bash
  ```

- 已部署的全栈实例需先安装匹配版本的更新控制面，再从管理页面执行更新；详见[更新指南](deploy/update-bridge/README.md)。
- Docker Compose 模板位于 [`deploy/`](deploy/)。请将 `SUB2API_IMAGE` 和 `SUB2API_QUALITY_RENDERER_IMAGE` 都设为同一 Release 版本；模板默认标签可能落后于最新版本。

安装脚本和 Release 均来自 `JayHome137/sub2api`；本分支的更新器不使用上游 Release。

## 许可证

本项目采用 [LGPL-3.0-or-later](LICENSE) 许可证。原项目版权归 Wesley Liddick 所有（2026）。
