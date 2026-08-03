# AIFoo 官方后端交付

此目录维护官方 Sub2API 后端镜像的验证、生产备份、单服务部署和镜像回滚流程。AIFoo 私有仓库不构建或定制后端；生产只运行官方稳定 Release 的 `weishaw/sub2api@sha256:...`。

## 自动同步边界

`upstream-sync.yml` 每 6 小时读取官方稳定 Release，合并完整官方 tag，并记录：

- annotated tag object 与 peeled release commit；
- 官方 Docker Hub 多架构镜像 digest；
- 后端运行时是否变化；
- 相对生产实际运行后端的累计 migration 文件；
- 后端生产部署是否仍等待人工批准。

定时流程只读 `[State] AIFoo production backend` Issue 中由成功部署工作流写入的版本、commit、官方 digest 和 migration tree。基线缺失时保守标记需要后端审批；基线损坏、tag/image 漂移或 migration 被修改、删除、重命名时失败关闭。它可以创建候选、运行 CI、合并符合现有 UI 规则的完整官方源码并更新 Issue，但没有 SSH 凭据引用，也不会调用任何 VPS helper。

## GitHub Runner 验证

`deploy-backend.yml` 只能从 `production` 手动触发。触发者必须是仓库所有者，并输入 `DEPLOY-AIFOO-BACKEND`。工作流会再次验证官方 Release、tag object、commit、不可变 digest、镜像 labels、版本输出和 `ready-for-vps` Issue 记录。

只读生产 preflight 返回当前官方镜像、Release 和 commit 后，GitHub Runner 使用固定 digest 的一次性 PostgreSQL 16 与 Redis 7，依次启动当前生产官方镜像、目标官方镜像、当前旧镜像。它验证真实升级 migrations、升级后 schema 上的 image-only rollback、版本/commit、健康和存储探针。测试资源在 Runner 内销毁，不连接生产数据库，也不上传数据库、Redis、配置或日志 Artifact。

## VPS 流程

1. `preflight` 只读检查 helper 哈希、Compose、磁盘、四个生产容器、PostgreSQL、Redis、本机 `/health`，并返回当前官方镜像基线和目标 digest 是否已经运行。
2. 若目标已经运行，工作流走 no-op：不 pull、不备份、不重建容器，只做只读状态和公网检查。
3. `stage` 只 pull 官方 digest，并在 `--network none` 条件下核对镜像 labels 与版本；不会启动连接生产网络的候选后端。
4. `backup` 保存原 Compose、`/opt/sub2api/data`、PostgreSQL custom-format dump、PostgreSQL globals、Redis RDB、migration 清单、旧后端镜像 tar 和前端/PostgreSQL/Redis 容器指纹，并验证 `SHA256SUMS`。
5. 工作流在备份后再次确认远端 `production` SHA 未变化。
6. `deploy` 只把 Compose 的 `sub2api.image` 改为官方 digest，并执行 `up -d --no-deps --force-recreate sub2api`。
7. 部署后验证镜像 ID、版本、commit、Docker/HTTP 健康、预期 migrations，并确认前端、PostgreSQL、Redis 的容器 ID、镜像、启动时间、挂载和网络均未变化。
8. 本机和公网后端验证通过后立即关闭自动回滚窗口，再检查未变化的 `/frontend-health` 与 `/login`；前端或 CDN 故障不会触发后端回滚。
9. 后端验证失败时只恢复备份中的精确旧后端镜像；重复调用恢复只验证旧状态，不再次重建。PostgreSQL 与 Redis 备份继续保留，不会由 Actions 自动恢复。
10. 成功或 no-op 验证后，工作流更新专用生产后端 State Issue，并清除 Release Issue 的 `backend-deploy-required`。

## 数据恢复边界

数据库恢复可能覆盖备份后产生的用户、余额、支付、用量和审计写入；Redis 中也可能存在尚未回写 PostgreSQL 的权威额度状态。为尽量保持服务在线，当前备份不会暂停全部 writer，因此 PostgreSQL dump、Redis RDB 和 data tar 是分别校验的应急备份，不宣称是跨存储的原子时间点。helper 故意不提供 `restore-database` 命令，Actions 也没有数据库自动恢复路径。

需要灾难恢复时，必须另行人工批准，停止全部写入者，在隔离数据库中真实验证 dump，并把同一备份中的 PostgreSQL 与 Redis 状态作为一组处理。普通镜像或健康检查失败只执行 image-only rollback。

## Helper 安装

生产机固定路径为 `/usr/local/sbin/deploy-sub2api-backend`，必须由 `root` 持有且不可被 group/world 写入。Actions 每次调用前都会比较该文件与仓库 `deploy/backend/deploy-backend.sh` 的 SHA-256；不一致时只读 preflight 直接阻断。
