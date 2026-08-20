# Sub2API 全量代码审计报告

审计日期：2026-08-19 至 2026-08-20
审计与加固分支：`codex/security-hardening-20260820`
原始审计基线：`7f20d2953 fix(sync): resolve upstream conflicts deterministically`；本轮加固起点：`8ad56ffcc Merge VM preflight workspace fix into production`
交付状态：原始审计修复已合并到远端 `production`；本轮安全加固在独立分支和 PR #70 推进，未触发生产部署。

## 1. 结论

仓库不是整体性的“屎山”；主链路、测试和前端构建都仍可验证。但有两类需要持续控制的风险：少数真实的后端安全/并发问题，以及两个过大的管理端 Vue 文件。

本轮已完成或正在验证的、安全可验证修复没有改变现有 UI：

1. 上游冲突 resolver 已覆盖普通文本、add/add、delete/modify、rename/delete 和二进制冲突；真正冲突的 `frontend/*` 保留 fork 版本，同时保留上游的非冲突 hunk。
2. 删除了未接入生产依赖图的 `GroupService`、`ProxyService` 及其 Wire provider，删除无调用的 `RedeemService.GetStats`，并删除无实际刷新逻辑的 `RefreshAccountCredentials`。
3. 删除无源码 import 的 `@lobehub/icons` 及仅为它保留的 Mermaid override；内联 SVG UI 未改变。
4. 修正 Redeem stats 测试路由，使其与生产路由一致。
5. 清理文档、示例配置和部署脚本中的固定凭据；部署下载失败时 fail-closed；自动生成的管理员密码不再进入 stdout/容器日志，只写入数据目录下的 `0600` 受保护文件；并对长占位 JWT 做拒绝校验。

仍需后续治理的项目被保留为明确 follow-up：API Key 明文清除、四个假统计 API、超大 Vue 文件、EasyPay 统一时间窗口和 xlsx advisory。这些项目分别需要滚动迁移/版本化合同/视觉回归/供应商协议或依赖替换证据；强行改动会比保留当前行为更容易中断生产或影响 UI。

## 2. 范围、方法与限制

- 范围：`backend/` 的认证、支付、订单、Webhook、数据访问；`frontend/` 的依赖、构建、源码和复杂度；`.github/` 与 `deploy/` 的上游同步、冲突解析和交付门禁。
- 方法：源码与调用链检索、Git 双边差异、依赖树、resolver fixture、工作流合同测试、前端 lint/typecheck/test/build、锁文件一致性与 `git diff --check`。
- 上游基线：共同祖先仍为 `e0c48a19ed794a565e3858662520afe0a1f9f0ba`（官方 `v0.1.178`）。截至 2026-08-20，分支相对尚未发布的 `upstream/main` 为本地独有 119 个提交、上游独有 63 个提交；双边修改重叠 10 个文件，Git 预演产生 2 个文本冲突，均命中现有 fork 保护策略。下一稳定 Release 出现后仍须在候选 SHA 上重跑完整门禁。
- 限制：本机初始没有系统 Go、Semgrep、govulncheck、ShellCheck 或 actionlint；本轮使用临时 Go 1.26.6 工具链完成核心包定向测试，完整 Go 编译/测试与 Go SAST 仍以远端 Actions 为最终证据。Semgrep、ShellCheck/actionlint 不在本轮已验证声明范围内。

## 3. 已确认问题与处置

| 编号 | 结论 | 状态 | 证据与处理边界 |
|---|---|---|---|
| C-01 | 支付实例日限额存在 TOCTOU 并发窗口 | 已定向修复，待本轮远端复核 | `load_balancer.go` 在订单事务内锁定实例并重算额度；`visibleMethodLoadBalancer` 转发 `InstanceCapacityReserver`，且包装对象缺少该能力时 fail-closed 为 503，不再静默绕过锁。远端 CI/VM 仍需对最终提交复核。 |
| C-02 | API Key 以明文存入 `api_keys.key` | 第一阶段已落地，仍有明文残余 | migration 227 增加可空 `key_hash`，migration 228 增加非事务 partial unique index；创建、认证、Exists 已 hash-first，旧明文双读并懒回填。为保持现有 UI/API 和滚动升级兼容，`key` 及列表/删除/缓存失效路径仍可能接触明文；第二阶段需迁移 DTO/缓存并清除旧列。 |
| C-03 | EasyPay webhook 未验证时间新鲜度 | 已增加同交易号重放防护，统一时间窗待协议证据 | 当前兼容层仍不强制猜测性的 timestamp；若已记录的 EasyPay 交易号再次用于取消/过期订单恢复，则拒绝并记录审计事件。不同兼容服务商的时间字段仍需真实样本后再增加窗口校验。 |
| C-04 | resolver 的缺失 stage 使合并卡住 | 已修复并验证 | 现在先检查 Git stage；策略侧不存在时显式暂存删除。fixture 覆盖 add/add、delete/modify、rename/delete、binary 和文本 hunk。 |
| C-05 | 前端根配置遗漏 UI 保护集合 | 已修复并验证 | 策略改为 `frontend/*`，未来前端根配置也受保护；fixture 已验证未知根配置文件。 |
| C-06 | `@lobehub/icons` 是无用直接依赖 | 已修复并验证 | 业务源码无 import，`pnpm why @lobehub/icons` 已无输出；删除后锁文件、测试和生产构建均通过。 |
| C-07 | 旧服务/空刷新接口造成冗余 | 已修复，待 Go 环境复核 | 删除未注入的 `GroupService`、`ProxyService`、Wire provider、无调用 `RedeemService.GetStats` 和无实现的 `RefreshAccountCredentials`。全仓引用与 Wire 检索无残留；本机无 Go，尚不能编译确认。 |
| C-08 | group/proxy/redeem/user usage API 返回假统计 | 已确认，保留兼容 | 四个生产路由仍注册，前端只保留 API 封装、未找到页面调用，外部调用方仍可能存在。group/user 可复用部分聚合但周期和成本口径未定义；`usage_logs` 没有 `proxy_id`，proxy 请求数/成功率/延迟无法正确计算；redeem 的状态/类型口径也已超出旧结构。不能删路由、改 501 或继续伪造“正常”数值。 |
| C-09 | 文档/示例含固定凭据；部署下载器曾不 fail-closed；自动管理员密码曾进入 stdout/容器日志 | 已修复并加合同测试 | 示例值改为空值或明确占位说明；`docker-deploy.sh` 使用失败即停与空文件检查；自动管理员密码原子写入数据目录下的 `0600` 文件，数据库创建失败时清理，日志只提示文件路径；相关部署文档不再指导从日志提取密码。 |
| C-10 | 长的 JWT 配置占位符可能绕过原有长度/重复字符检查 | 已修复并测试 | `isWeakJWTSecret` 拒绝已知长占位符，配置单测覆盖默认示例值。 |

## 4. 复杂度与供应链结论

- `SettingsView.vue` 为 12,999 行，`GroupsView.vue` 为 6,840 行，是最明显的维护风险；二者不是可在本轮无视觉回归保障下安全拆分的“死代码”。建议以领域为单位单独拆分，并为每一步增加组件和视觉回归。
- 前端生产构建仍报告大 chunk：`AccountsView` 约 738 kB；另有静态/动态 import 重复、过期 Browserslist 数据和 Node shell deprecation warning。这些均未导致构建失败，属于后续性能/工具链治理，不应混入当前冲突修复。
- `xlsx@0.18.5` 仍有两个高危 advisory：`GHSA-4r6h-8v6p-xvw6` 与 `GHSA-5pgg-2g8v-p4x9`。当前前端仅在 `UsageView.vue` 导出 xlsx，不读取用户上传的 xlsx，实际可达面较窄；npm 无可直接升级的修复版本，改用供应商 CDN 版本应另做来源、许可和回归评估。
- AES legacy ciphertext fallback 与历史迁移是兼容层，不是可删除的冗余代码；本轮未动。

## 5. 可持续上游合并流程

当前规则已落地为：

1. 稳定上游 Release 进入候选分支。
2. resolver 对真正冲突的 `frontend/*`、CI/同步脚本、部署合同和安全示例（包括 `deploy/docker-deploy.sh`、空凭据模板及其合同测试）取 fork 侧；其他冲突取上游侧；不冲突的双方改动由三方合并保留。
3. 对 add/delete/rename/binary 按 Git stage 选择或暂存删除，不留下 `U` 状态。
4. resolver、合同测试、前端验证、候选 SHA/digest 检查通过后才进入预加载和网页手动激活。
5. 无法通过验证的候选只停止该候选，不部署、不污染下次同步；后续上游检查仍可继续运行。

这满足“尽量自动合并、UI 不被上游冲突覆盖、流程持续运行”。但不能诚实地把语义冲突或验证失败静默当成成功：这类候选必须留下诊断并等待定向修复，否则会把坏版本自动推入生产。

## 6. 本轮验证

| 检查 | 结果 |
|---|---|
| `sh .github/scripts/resolve-upstream-conflicts-test.sh` | 通过，含文本、add/add、delete/modify、rename/delete、binary、未来前端根配置和部署安全合同 fixture |
| `sh deploy/frontend/workflow-contract-test.sh` | 通过 |
| `sh deploy/backend/workflow-contract-test.sh` | 通过 |
| `corepack pnpm@10.28.2 install --frozen-lockfile --offline` | 通过 |
| `pnpm run lint:check` | 通过 |
| `pnpm run typecheck` | 通过 |
| `pnpm exec vitest run --reporter=dot --silent` | 233 个文件、1,639 个测试全部通过 |
| `pnpm run build` | 通过；仅有第 4 节列出的 warning |
| `pnpm audit --prod` | 仅剩 `xlsx` 的两个已知 high advisory |
| `sh deploy/tests/docker-deploy-security-test.sh` | 通过；验证下载 fail-closed、空响应拒绝和凭据不回显 |
| `bash -n`/`sh -n`（4 个改动 shell 脚本）与 `git diff --check` | 通过 |

已推送提交 `980be1f81` 对应的远端检查也全部通过：CI `32283716587`、Security Scan `32283716275`、Validate AIFoo frontend `32283716226`。这些检查覆盖 Go 单元/集成测试、shell 合同、golangci-lint、前后端安全扫描、lint/typecheck/Vitest/生产构建、Playwright、Docker image smoke 与 backup/restore。

最终提交 `c04361bae6e4ee8c4694908857d07037c19c715b` 的远端证据：

- CI `32292417011`：shell、Go unit/integration、golangci-lint 全部成功；macOS 子 job 按 workflow 条件 skipped。
- Security Scan `32292416699`：backend-security、frontend-security 成功。
- Validate AIFoo frontend `32292416743`：frontend、image、attest 成功；publish 按未请求生产发布的规则 skipped。frontend job 实际通过 lint/typecheck、Vitest、生产构建、Chromium/Playwright；image job 实际通过容器 smoke 与部署 backup/restore 集成。
- PR #65 已合并，代码合并提交为 `b2643d1c75d3269cf8dc537f78188bbdf9d55ff4`；随后 PR #66 合并审计证据文档，最终远端 `origin/production` 已核对为 `8816c4ed872b6e050d17c70deb4d7a9599e51163`。
- 合并后的 push 仅触发了配置为 skipped 的 macOS Shell CI；没有触发 deploy、frontend activation 或 backend activation workflow。
- 只读公网探针（2026-08-20 Asia/Shanghai）：`https://<redacted-domain>/health`、`/frontend-health` 返回 HTTP 200 和 `{"status":"ok"}`；Landing `/` 与 `/login` 返回 HTTP 200，安全响应头存在。
- 旧的 VPS Read-only Preflight（运行记录已脱敏）因错误使用 `ubuntu-latest` 未进入 runner，GitHub annotation 为账户付款失败/消费上限。随后两个 job 改为受信任的 self-hosted Linux VM；首次 VM 运行证明 frontend preflight 成功，但暴露持久化 workspace 的 `official` remote 不是幂等操作。后续改为 `set-url-or-add` 并更新合同测试，最终两个 job 均成功：backend `target_state=current`、`preflight_result=ready`，frontend `blocker_count=0`、`preflight_result=ready`。全程未执行部署、重启或生产写操作。
- PR #69 的最终 workflow 修复已合并，远端 `origin/production` 当前为 `8ad56ffcc1ed3d3e663be725baac5744335cc24c`；该提交只改变 preflight runner/持久化 remote 处理和合同测试，不改变 UI。

## 7. 后续优先级

1. 在最终远端 CI/VM 复核 C-01 的事务锁路径；必要时补 PostgreSQL 并发集成测试。
2. 完成 C-02 第二阶段：迁移认证缓存/DTO 与管理端读取边界，分批清除 `api_keys.key` 明文并保留可回滚窗口。
3. 确定 C-08 的统计口径和 API 兼容承诺后，再实现真实统计或走版本化弃用。
4. 收集实际 EasyPay 服务商 webhook 样本/协议后，再决定是否加入 C-03 时间窗口。
5. 单独建立带视觉回归的 `SettingsView` / `GroupsView` 渐进拆分任务；不要把它混入上游同步变更。
