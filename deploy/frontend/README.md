# AIFoo 前端交付

此目录维护源码级 AIFoo UI、公开 Landing 页面和独立 Nginx 前端镜像。生产环境不再使用 `sub_filter` 或运行时 override 脚本。

## 分支

- `main`：官方 `Wei-Shaw/sub2api` 主分支镜像。
- `production`：AIFoo 生产代码。
- `upgrade/vX.Y.Z`：由 `upstream-sync.yml` 创建的官方稳定版升级候选。

上游版本只通过 Pull Request 进入 `production`。合并后 `validate.yml` 生成候选镜像；生成镜像不会自动部署。

## 验证

本地前端验证使用锁定的 pnpm：

```bash
cd frontend
corepack pnpm@10.28.2 install --frozen-lockfile
corepack pnpm@10.28.2 run lint:check
corepack pnpm@10.28.2 run typecheck
corepack pnpm@10.28.2 run test:e2e
corepack pnpm@10.28.2 run build
```

GitHub Actions 额外运行官方关键 Vitest、AIFoo 集成测试、桌面与移动端 Playwright，并构建 `ghcr.io/jayhome137/sub2api-frontend`。

## 部署与回滚

`deploy.yml` 只接受完整的 `sha256:` 镜像 digest。VPS 上的受限用户只能调用 root 持有的 `deploy-frontend.sh` 规定命令；脚本会：

1. 拉取并核对指定 digest。
2. 在 `127.0.0.1:18080` 启动带固定标签的隔离候选容器。
3. 验证 Landing、SPA、后端代理和旧 override 资源的 `404`，通过后才进入生产部署。
4. 备份 Compose 与旧 Landing，只重建 `frontend` service。
5. 验证生产前端和后端健康状态，失败时恢复原 Compose 并重建旧前端。
6. 无论部署成功或失败都清理候选容器。

后端、PostgreSQL 和 Redis 不在此部署脚本的修改范围内。
