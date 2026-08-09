# AIFoo 前端交付

此目录维护源码级 AIFoo UI、公开 Landing 页面和独立 Nginx 前端镜像。生产环境不再使用 `sub_filter` 或运行时 override 脚本。

## 分支

- `production`：AIFoo 生产代码。
- `upgrade/vX.Y.Z`：由 `upstream-sync.yml` 从官方正式 Release tag 创建的升级候选。

`upstream-sync.yml` 每天北京时间 01:00（GitHub cron 为 17:00 UTC）查询一次 `Wei-Shaw/sub2api` 最新正式 Release，不同步官方 `main`、draft 或 prerelease。候选分支依次运行 CI、安全扫描、AIFoo 测试、生产构建与容器 smoke test：

- 没有 UI 相关路径变更时，验证通过后自动合入 `production`，对最终提交重新验证并生成私有前端镜像。
- `frontend/`、`deploy/frontend/`、`docs/legal/`、`backend/internal/web/` 或可能改变前端 API 契约的后端路径发生变化时，PR 保留等待 AIFoo UI 检查，不自动合并或发布镜像。
- UI 适配和人工检查完成后，手动运行同步工作流并设置 `retry_existing=true`、`approve_ui=true`；工作流会重新验证精确候选 SHA 和未变化的 `production` 基线后才允许合并。
- 若 `production` 已更新但最终 Runner、Artifact 或 GHCR 发布失败，后续定时检查会在候选分支仍精确指向当前 `production` 时自动重跑最终构建和发布；也可手动设置 `retry_final=true`。
- 每个新 Release 创建一个分配给仓库所有者的 Issue，使用 `candidate-testing`、`ui-review-required`、`sync-failed` 和 `ready-for-vps` 标记进度。

私有仓库只构建 `deploy/frontend/Dockerfile`；后端不从私有源码构建。同步流程会记录官方后端 tag、commit 和 `weishaw/sub2api@sha256:...`，后端部署仍由独立的 `deploy-backend.yml` 完成，详见 `deploy/backend/README.md`。每天的检测、合并、验证和构建不会自动部署到 VPS。

验证完成并出现 `ready-for-vps` 后，管理员可在网页版本面板点击“立即更新”。独立的 `update-bridge` 先用现有 Sub2API 管理员认证回查身份，再固定触发 `web-update.yml`；网页点击就是本次明确的生产批准。该编排只解析 Issue 已记录的前后端不可变 digest，然后顺序复用 `deploy-backend.yml`（仅需要时）和 `deploy.yml`。原有 Hosted Runner 预检、完整备份、健康检查和自动回滚逻辑不变，浏览器不会接触 GitHub Token。桥接服务的生产安装见 `deploy/update-bridge/README.md`。

## 验证

本地前端验证使用锁定的 pnpm：

```bash
cd frontend
corepack pnpm@10.28.2 install --frozen-lockfile
corepack pnpm@10.28.2 run lint:check
corepack pnpm@10.28.2 run typecheck
corepack pnpm@10.28.2 exec vitest run
corepack pnpm@10.28.2 run test:e2e
corepack pnpm@10.28.2 run build
```

GitHub Actions 运行官方关键 Vitest、AIFoo 集成测试、全量 Vitest、桌面与移动端 Playwright。随后使用临时本地 Registry、旧版无 HEALTHCHECK 的 Nginx 前端和真实 Docker Compose，执行完整的 `stage -> backup -> deploy -> restore` 集成测试；全部通过后才把同一前端镜像推送到私有 `ghcr.io/jayhome137/sub2api-frontend`。

## VPS 只读预检

`VPS Read-only Preflight` 只能手动触发，并绑定现有 `production` Environment。工作流沿用受限 SSH 用户，只允许通过无交互 `sudo` 调用 root 持有的 `deploy-sub2api-frontend preflight` 固定子命令；不传输或执行任意远端脚本，也不会拉取镜像、启动容器、备份、重启服务或修改配置。它检查主机资源、Docker/Compose、服务和容器状态、前端挂载、staging 端口，以及部署 helper 是否与仓库 SHA-256 一致。

任何阻断项都会让工作流失败。部署 helper 缺失、权限不安全或哈希不一致时，只报告问题；安装或更新 helper 必须等到用户另行授权。预检不会写入部署文件，但 SSH 连接仍可能由系统自动追加认证或审计日志，这类系统日志不属于可承诺消除的“零写入”。

## 部署与回滚

`deploy.yml` 只接受完整的 `sha256:` 镜像 digest，并要求该 digest、镜像源码提交和 `ready-for-vps` Issue 记录一致；镜像源码到当前 `production` 之间不得出现镜像构建输入变化。VPS 上的受限用户只能调用 root 持有的 `deploy-frontend.sh` 规定命令；脚本会：

部署只能从 `production` 分支触发，触发者必须是仓库所有者。直接运行工作流时仍需输入 `DEPLOY-AIFOO-FRONTEND` 确认短语；网页入口则由已验证的管理员点击触发固定 `web-update.yml`，再通过 `workflow_call` 传入同一确认短语。该代码级门禁用于私人仓库套餐不支持 Environment Required Reviewer 时，确保镜像发布不会自行进入 VPS 部署。

1. 拉取并核对指定 digest。
2. 在 `127.0.0.1:18080` 启动带固定标签的隔离候选容器。
3. 验证 Landing、SPA、后端代理和旧 override 资源的 `404`，通过后才进入生产部署。
4. 显式执行 `backup <digest>`，以运行容器的原始 image ID 为只读基底，把实际 Nginx 配置和 HTML 封装成唯一的回滚镜像，同时备份 Compose、旧 Landing 与容器元数据，并校验 `SHA256SUMS`。原始镜像不得声明 `VOLUME`，前端运行挂载只能位于 `/etc/nginx` 或 `/usr/share/nginx/html`；不满足任一条件都拒绝继续。
5. 备份记录旧版、候选和回滚三份 Compose 的 SHA-256。候选和回滚 Compose 会移除旧前端 service 的 `volumes` 与 `healthcheck` 覆盖，由不可变镜像提供内容和自身健康契约。`deploy <digest> <backup-id>` 仅接受与候选 digest、当前镜像和当前 Compose 精确匹配的备份，并写入本次部署状态后只重建 `frontend` service。
6. 候选镜像必须通过 Docker HEALTHCHECK、`/frontend-health`、后端代理和关键路由验证。旧版或回滚镜像允许没有 Docker HEALTHCHECK 和 `/frontend-health`，但仍必须处于 `running` 并通过 `/health`、Landing 与登录路由验证。
7. 部署失败、部署进程异常退出或 SSH 命令被中断时，载入已验证的回滚镜像并恢复旧前端。`restore` 只接受备份记录的精确镜像、Compose 和部署状态；已经处于旧版或回滚状态时只验证，不重复重建。
8. 公网 smoke test 失败时，Actions 调用 `restore <digest> <backup-id>`，随后再次从公网验证 `/health`、Landing 与 `/login`。
9. 无论部署成功或失败都清理候选容器。

后端、PostgreSQL 和 Redis 不在此部署脚本的修改范围内。
