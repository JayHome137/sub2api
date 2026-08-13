# AIFoo 官方后端交付

此目录只负责验证并切换官方稳定 Release 的 `weishaw/sub2api@sha256:...`。AIFoo 不定制后端；前端 UI 仍由私有镜像维护。

## 按钮出现前

`upstream-sync.yml` 每 3 小时（北京时间 02:17、05:17、…）检查官方稳定 Release。候选源码、必要 CI、UI 兼容、前端镜像均通过后：

- 前端镜像预加载到 VPS；
- 仅在官方后端运行时变化时，`backend-preparation.yml` 验证官方 tag、commit、不可变镜像和 migration 计划；
- Runner 用隔离 PostgreSQL/Redis 验证升级及 image-only rollback；
- VPS 只预拉取目标镜像，并保存当前 Compose、旧镜像引用和容器指纹作为本机回滚状态；
- 不切换容器、不修改 Compose、不接触生产数据。

前端 `vps-preloaded`，以及后端变化时的 `backend-prepared`，全部完成后才添加 `ready-for-vps`，网页才显示一键更新。

## 点击一键更新后

纯前端更新只激活已预加载前端镜像。

后端更新只执行：

1. 核对 prepared state 未漂移；
2. 有 migration 时导出一次当前 Sub2API PostgreSQL custom dump，无 migration 时不创建备份目录；
3. Compose 仅替换 `sub2api.image`，重建后端单个服务；
4. 核对镜像、版本、commit、migration 和一次公网健康检查；
5. 失败时用 VPS 本机保留的旧镜像和 prepared Compose 恢复后端。

点击路径不会重新 pull 镜像、运行隔离升级测试或重复完整 CI。

## 数据边界

- 纯前端：不备份生产数据。
- 后端无 migration：不备份业务数据；仅使用按钮出现前保存的旧镜像/Compose 回滚元数据。
- 后端有 migration：只导出当前应用 PostgreSQL custom dump，并以 `pg_restore --list` 校验。
- 不执行 `pg_dumpall`、Redis BGSAVE、`/opt/sub2api/data` tar 或 Docker image save/load。
- 数据库 dump 不由 Actions 自动恢复；恢复生产数据库必须另行人工批准。
- 若生产显式启用了 `database.user_platform_quota_flusher_enabled`，含 migration 的自动准备会暂停，避免把 Redis 仍为权威的额度状态遗漏在 PostgreSQL dump 之外；仓库默认值为关闭。

## Helper 安装边界

生产 helper 固定为 `/usr/local/sbin/deploy-sub2api-backend`，须由 root 持有且 group/world 不可写。工作流用仓库 helper 的 SHA-256 做 preflight；helper 尚未按新版本更新到 VPS 时，准备流程会安全阻断，不会切换生产。

`deploy-update-components.yml` 是唯一的 helper/网页更新 bridge 维护入口：只能由仓库 owner 在 `production` 显式确认后调用 VPS 上已部署的 root-owned `deploy-update-components` 维护命令。首次启用必须由 VPS root 管理通道安装该命令、root 持有的签名公钥和窄 sudo 规则；工作流只上传由 GitHub Secret 私钥签名的 manifest。它会在 SSH 前完成 bridge 的 Go 测试与构建，在写入前由 VPS 制作本机备份，随后只重启 `aifoo-update-bridge` 并验证 helper/bridge SHA 与本地 `/health`；不会操作 Docker Compose、数据库、Nginx 或 Sub2API 服务。
