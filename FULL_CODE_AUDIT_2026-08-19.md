# Sub2API 全量代码审计报告

审计日期：2026-08-19
审计分支：`production`
审计基线：`7f20d2953 fix(sync): resolve upstream conflicts deterministically`
交付状态：以下修复均在本地工作树，未提交、未推送、未部署。

## 1. 结论

仓库不是整体性的“屎山”；主链路、测试和前端构建都仍可验证。但有两类需要持续控制的风险：少数真实的后端安全/并发问题，以及两个过大的管理端 Vue 文件。

本轮已完成的、安全可验证的修复没有改变现有 UI：

1. 上游冲突 resolver 已覆盖普通文本、add/add、delete/modify、rename/delete 和二进制冲突；真正冲突的 `frontend/*` 保留 fork 版本，同时保留上游的非冲突 hunk。
2. 删除了未接入生产依赖图的 `GroupService`、`ProxyService` 及其 Wire provider，删除无调用的 `RedeemService.GetStats`，并删除无实际刷新逻辑的 `RefreshAccountCredentials`。
3. 删除无源码 import 的 `@lobehub/icons` 及仅为它保留的 Mermaid override；内联 SVG UI 未改变。
4. 修正 Redeem stats 测试路由，使其与生产路由一致。

尚不能安全“顺手修掉”的项目被保留为明确 follow-up：支付限额并发竞态、API Key 明文存储、四个假统计 API、超大 Vue 文件，以及 EasyPay 时间字段兼容性。这些项目都需要事务/迁移/协议或视觉回归证据；强行改动会比保留当前行为更容易中断生产或影响 UI。

## 2. 范围、方法与限制

- 范围：`backend/` 的认证、支付、订单、Webhook、数据访问；`frontend/` 的依赖、构建、源码和复杂度；`.github/` 与 `deploy/` 的上游同步、冲突解析和交付门禁。
- 方法：源码与调用链检索、Git 双边差异、依赖树、resolver fixture、工作流合同测试、前端 lint/typecheck/test/build、锁文件一致性与 `git diff --check`。
- 上游基线：共同祖先为 `e0c48a19ed794a565e3858662520afe0a1f9f0ba`；本地独有 103 个提交、上游独有 39 个提交。双边实际修改重叠仅 3 个后端文件：`gateway_handler.go`、`channel_monitor_quota_fetcher.go`、`gateway_service.go`。
- 限制：本机没有 Go、Semgrep、govulncheck、ShellCheck 或 actionlint，因而不能宣称 Go 编译/测试、Go SAST、ShellCheck 或 actionlint 已通过。

## 3. 已确认问题与处置

| 编号 | 结论 | 状态 | 证据与处理边界 |
|---|---|---|---|
| C-01 | 支付实例日限额存在 TOCTOU 并发窗口 | 待定向修复 | `load_balancer.go` 先读取 `dailyUsed`，`payment_order.go` 随后在另一个订单事务写入；两个请求可同时通过。需要在订单事务内锁定/原子保留实例容量，并做 PostgreSQL 并发测试。 |
| C-02 | API Key 以明文存入 `api_keys.key` | 待兼容迁移 | schema、创建和认证查询都直接使用明文。需要哈希索引列、新 Key 哈希、旧 Key 双读迁移和最终清除方案，不能一次性改列使现有 Key 失效。 |
| C-03 | EasyPay webhook 未验证时间新鲜度 | 待协议证据 | 当前只验证签名。代码未证明所有兼容 EasyPay 服务商都会发送统一、可解析的时间字段；直接拒绝无时间字段的通知可能中断真实付款，故本轮未加入猜测性的窗口校验。 |
| C-04 | resolver 的缺失 stage 使合并卡住 | 已修复并验证 | 现在先检查 Git stage；策略侧不存在时显式暂存删除。fixture 覆盖 add/add、delete/modify、rename/delete、binary 和文本 hunk。 |
| C-05 | 前端根配置遗漏 UI 保护集合 | 已修复并验证 | 策略改为 `frontend/*`，未来前端根配置也受保护；fixture 已验证未知根配置文件。 |
| C-06 | `@lobehub/icons` 是无用直接依赖 | 已修复并验证 | 业务源码无 import，`pnpm why @lobehub/icons` 已无输出；删除后锁文件、测试和生产构建均通过。 |
| C-07 | 旧服务/空刷新接口造成冗余 | 已修复，待 Go 环境复核 | 删除未注入的 `GroupService`、`ProxyService`、Wire provider、无调用 `RedeemService.GetStats` 和无实现的 `RefreshAccountCredentials`。全仓引用与 Wire 检索无残留；本机无 Go，尚不能编译确认。 |
| C-08 | group/proxy/redeem/user usage API 返回假统计 | 已确认，保留兼容 | `group_handler.go`、`proxy_handler.go`、`redeem_handler.go`、`admin_user.go` 返回固定 0 值；部分接口仍被前端 API 层暴露，也可能被外部调用。统计口径未定义，不能删路由、改 501 或伪造数值。 |

## 4. 复杂度与供应链结论

- `SettingsView.vue` 为 12,999 行，`GroupsView.vue` 为 6,840 行，是最明显的维护风险；二者不是可在本轮无视觉回归保障下安全拆分的“死代码”。建议以领域为单位单独拆分，并为每一步增加组件和视觉回归。
- 前端生产构建仍报告大 chunk：`AccountsView` 约 738 kB；另有静态/动态 import 重复、过期 Browserslist 数据和 Node shell deprecation warning。这些均未导致构建失败，属于后续性能/工具链治理，不应混入当前冲突修复。
- `xlsx@0.18.5` 仍有两个高危 advisory：`GHSA-4r6h-8v6p-xvw6` 与 `GHSA-5pgg-2g8v-p4x9`。当前前端仅在 `UsageView.vue` 导出 xlsx，不读取用户上传的 xlsx，实际可达面较窄；npm 无可直接升级的修复版本，改用供应商 CDN 版本应另做来源、许可和回归评估。
- AES legacy ciphertext fallback 与历史迁移是兼容层，不是可删除的冗余代码；本轮未动。

## 5. 可持续上游合并流程

当前规则已落地为：

1. 稳定上游 Release 进入候选分支。
2. resolver 对真正冲突的 `frontend/*` 与 fork 交付文件取 fork 侧；其他冲突取上游侧；不冲突的双方改动由三方合并保留。
3. 对 add/delete/rename/binary 按 Git stage 选择或暂存删除，不留下 `U` 状态。
4. resolver、合同测试、前端验证、候选 SHA/digest 检查通过后才进入预加载和网页手动激活。
5. 无法通过验证的候选只停止该候选，不部署、不污染下次同步；后续上游检查仍可继续运行。

这满足“尽量自动合并、UI 不被上游冲突覆盖、流程持续运行”。但不能诚实地把语义冲突或验证失败静默当成成功：这类候选必须留下诊断并等待定向修复，否则会把坏版本自动推入生产。

## 6. 本轮验证

| 检查 | 结果 |
|---|---|
| `sh .github/scripts/resolve-upstream-conflicts-test.sh` | 通过，含文本、add/add、delete/modify、rename/delete、binary、未来前端根配置 fixture |
| `sh deploy/frontend/workflow-contract-test.sh` | 通过 |
| `sh deploy/backend/workflow-contract-test.sh` | 通过 |
| `corepack pnpm@10.28.2 install --frozen-lockfile --offline` | 通过 |
| `pnpm run lint:check` | 通过 |
| `pnpm run typecheck` | 通过 |
| `pnpm exec vitest run --reporter=dot --silent` | 233 个文件、1,639 个测试全部通过 |
| `pnpm run build` | 通过；仅有第 4 节列出的 warning |
| `pnpm audit --prod` | 仅剩 `xlsx` 的两个已知 high advisory |
| `sh -n`（3 个改动 shell 脚本）与 `git diff --check` | 通过 |

## 7. 后续优先级

1. 在具备 Go 与 PostgreSQL 并发测试环境后，定向修复 C-01；这是唯一会直接突破支付限额的已确认运行时竞态。
2. 设计并测试 C-02 的 API Key 哈希兼容迁移；不要直接覆盖现有明文列。
3. 确定 C-08 的统计口径和 API 兼容承诺后，再实现真实统计或走版本化弃用。
4. 收集实际 EasyPay 服务商 webhook 样本/协议后，再决定是否加入 C-03 时间窗口。
5. 单独建立带视觉回归的 `SettingsView` / `GroupsView` 渐进拆分任务；不要把它混入上游同步变更。
