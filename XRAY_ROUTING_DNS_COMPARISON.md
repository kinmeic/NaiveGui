# NaiveGui 与 Xray-core 分流 / DNS 对照分析

## 对照范围

- NaiveGui 基线：`002115d`（v3.6 后的版本同步提交）
- Xray-core 基线：`50231eaf`（v26.7.11）
- Xray 重点文件：`app/router/router.go`、`app/router/condition.go`、`features/routing/dns/context.go`、`app/dns/dns.go`、`app/dns/cache_controller.go`、`app/dns/nameserver_cached.go`、`app/dns/nameserver_doh.go`

两者定位不同：Xray 是通用代理内核，NaiveGui 是 macOS 上围绕 NaiveProxy 的轻量 GUI 与本地分流代理。因此值得借鉴的是分层、触发时机和失败语义，不应为了功能数量直接复制 Xray 的全部配置面。

## 核心结论

NaiveGui v3.6 已经解决了最影响浏览体验的基础问题：A/AAAA 并行、DoH 会话复用、同域名在途请求合并、普通 GeoIP Direct 场景冷缓存不阻塞、系统代理只作用于活跃网络服务。这条低延迟方向是正确的。

本次审查发现的主要不足是：

1. DNS wire response 只提取 Answer，没有校验 HTTP 状态、事务 ID、QR/RCODE，也忽略服务端 TTL。
2. 固定 5 分钟缓存且无容量上限；刷新失败时没有 stale 结果可用。
3. 超时返回后没有主动取消 URLSession task。
4. 缓存和 singleflight key 未规范化，`Example.COM`、`example.com.` 会重复解析。
5. 所有 rule-set 都被当作可能含 IP，导致纯域名 `geosite-*` 规则也会触发 DoH；Block geosite 甚至会把它升级为同步等待。这是 DoH + System Proxy 卡顿的一条明确路径。
6. 用户规则中的多个 condition 当前等价于多个独立规则（ANY）；Xray 同一规则中的条件为 AND。界面没有说明这一语义，不能直接改成 AND，否则会静默改变旧配置行为。

## 架构与行为对照

| 方面 | Xray-core | NaiveGui 审查前 | 本次处理 |
| --- | --- | --- | --- |
| DNS 触发策略 | `AsIs`、`IPOnDemand`、`IPIfNonMatch`；读取 Target IP 时才解析 | 全局安全启发式；遇到 IP/rule-set 条目时解析 | 保留低延迟启发式；纯 geosite 按实际内容跳过 DNS |
| 单次路由解析复用 | `ResolvableContext` 在一次判定内缓存成功/失败 | `resolvedIPs` 惰性变量 | 已有，保留 |
| 并发去重 | `singleflight`，按域名和地址族 | 同 host in-flight 合并 | 已有，补充规范化 key |
| A / AAAA | 可按 queryStrategy 选择，并可并行 | 固定并行查询两者 | 保留；地址族策略列入下一阶段 |
| DNS 响应校验 | 完整 DNS 消息处理、RCODE/TTL | 只解析 Answer IP | 校验 HTTP 2xx、事务 ID、QR、RCODE、边界，并读取 TTL |
| 缓存 | A/AAAA 分离、TTL、清理、serve-stale | A/AAAA 合并、固定 TTL、无上限 | 服务端 TTL（30s–1h 限幅）、LRU 上限 2048、正缓存 stale 1h |
| 失败行为 | fallback server、skipFallback、disableFallback 等显式配置 | 单 DoH 服务；空结果交给路由安全策略 | 保留隐私友好的单服务默认；失败短缓存，刷新失败复用 stale |
| DoH 连接 | 长连接 / HTTP2，递归保护 | 持久 URLSession，经 naive SOCKS | 已有；补 HTTP 状态校验和超时取消 |
| DNS 服务器选择 | 可按域名为不同服务器分流 | 单一全局 provider | 暂不扩张；建议后续增加显式 fallback / split DNS |
| 返回 IP 过滤 | expected/unexpected IP，可防污染或限定结果 | 无 | 建议后续以可配置方式增加，不能默认过滤私网地址 |
| 静态 hosts | 支持域名替换和静态地址 | 无 | 建议仅在有真实需求时加入 |
| 路由条件 | 同一规则内条件 AND，规则有序 | 每个 condition 被展开，效果为 ANY | 保持兼容；建议增加显式 Any/All 模式 |
| 规则维度 | 域名、IP、端口、网络、用户、入站、协议、属性等 | 域名、CIDR、rule-set | 对本项目主要场景已够用；端口/网络类型是更有价值的下一项 |
| 动态更新 | 规则/平衡器可动态重载 | 启动时构建 matcher，rule-set 后台加载 | 可用；建议后续做原子规则快照热更新 |
| 可观测性 | 较细的 DNS / routing 日志 | 主要记录最终 action/reason | 建议增加 cache hit、stale、DoH latency、fallback 原因指标 |

## 本次已落地改进

### DNS 正确性和韧性

- 拒绝非 2xx DoH HTTP 响应。
- 校验 DNS response 的事务 ID 和 QR 标志；只接受 NOERROR / NXDOMAIN，SERVFAIL 等不会污染可信缓存。
- 对 Question/Answer 做完整边界检查，畸形长度不再被部分接受。
- 读取 A/AAAA record TTL，正缓存使用 30 秒到 1 小时的安全限幅。
- NXDOMAIN/NODATA 与传输失败短暂负缓存，避免连接风暴时重复查询。
- 正缓存过期后最多保留 1 小时 stale；立即供路由使用并后台刷新，刷新失败继续使用最后可信地址。
- 最多保存 2048 个域名，过期优先清理，其余按最近使用时间淘汰。
- 规范化域名大小写、首尾空白和根标签点，提高 cache/singleflight 命中率。
- A/AAAA 合并结果保持顺序去重。
- DoH 请求超时后主动取消任务。
- 配置代次切换后，旧会话的迟到结果不会返回给 leader 或写入新缓存。

### 分流热路径

- `geosite-*` 不再被全局策略误认为 IP 规则，因此 geosite Block 不会让所有未命中网站同步等待 DoH。
- rule-set 加载后递归检查是否真的含 CIDR；纯域名规则树（包括 invert/AND 子树）完全不触发 DNS。
- 含 CIDR 的 geoip/自定义规则仍保持原有 fail-closed 安全行为。

## 建议的下一阶段

### P1：显式但兼容的路由语义

1. 为用户规则增加 `Any / All` 条件模式，旧配置默认 `Any`，新建规则可显式选择。不要直接把旧规则改成 Xray 的 AND。
2. 增加 DNS routing strategy：建议保留当前 `Adaptive` 为默认，并提供 `As Is`、`IP If Non-Match`、`IP On-Demand` 高级选项。严格模式会增加冷缓存等待，必须在 UI 说明延迟与精确性的权衡。
3. 将规则判定上下文独立成可测试类型，直接覆盖“域名首轮、IP 次轮、失败回退、规则顺序、多 IP 命中”场景。

### P1：地址族与连接策略

1. 增加 `IPv4 + IPv6 / IPv4 only / IPv6 only / Prefer IPv4 / Prefer IPv6`。
2. 直连不要简单使用解析结果第一项；应采用 Happy Eyeballs 式竞速或根据当前网络可用地址族排序，否则 AAAA 可解析但 IPv6 路径不可达时仍会慢。
3. 将 A/AAAA 缓存拆开，避免一类记录短 TTL 迫使另一类一起刷新。

### P2：多 DNS 与 split DNS

1. 支持主 DoH + 可选 fallback；默认关闭 fallback，避免未经用户同意把域名发送给第二服务商。
2. fallback 应区分 NXDOMAIN、SERVFAIL、超时与结果过滤失败，不能看到空数组就盲目查询下一家。
3. 如加入企业/局域网场景，再支持按域名选择 DNS 和静态 hosts。
4. expected/unexpected IP 过滤应是规则化配置；默认拒绝私网回答会破坏内网域名，不应照搬成硬编码安全策略。

### P2：可观测性和运维

- 增加 DNS cache hit/miss/stale、query latency、HTTP/DNS error、同步安全回退计数。
- 日志明确区分“未启用 DoH”“冷缓存异步预取”“可信负响应”“传输失败”“规则集尚未加载”。
- rule-set 下载统一使用带 HTTP 状态校验、超时、任务取消和原子替换的下载器。

## 不建议直接照搬的部分

- Xray 的多入站、用户、协议嗅探、balancer 和大量路由维度会显著增加 NaiveGui 的配置复杂度，当前没有足够收益。
- 默认并行询问多个公共 DNS 会增加隐私暴露面，也可能因答案不一致使路由不稳定。
- 把严格 `IPIfNonMatch` 设为默认会重新引入用户已经遇到的冷缓存卡顿；它适合作为精确模式，而不是默认模式。
- 默认过滤 DNS 返回的私网地址会破坏局域网、企业 split-horizon DNS；应通过显式策略解决 DNS rebinding 风险。

## 验证

- Debug universal build（arm64 + x86_64）通过。
- 34 个测试全部通过；新增覆盖 TTL、NXDOMAIN、事务 ID、QR、截断响应、域名规范化，以及 geosite/geoip 的同步策略差异。
