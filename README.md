# Riverside Reactions Patches

本仓库的 `main` 已从完整 Discourse reactions 插件 fork 改为小型补丁集合。
请保留 Discourse 自带的 `plugins/discourse-reactions`，不要再删除官方插件，
也不要将本仓库克隆到 `plugins/discourse-reactions`。

效果：帖子外部直接展示每种表情及其数量，例如 `👍 12 😂 5 ❤️ 3`；
电脑最多一行、手机最多两行，超出种类用 `⋯ +N` 折叠，并隐藏重复的总数。
N 为隐藏的表情种类数，点击后通过官方回应详情查看全部。
以当前 Discourse 的官方实现为基础，保留显示定制，并补齐 reaction 的禁用表情校验。
补丁新增一个布尔设置 `discourse_reactions_show_individual_counts`，默认开启以保持
Riverside 当前展示。管理员可在 Reactions 插件设置或全站设置搜索该名称：

- 开启：每种表情显示数量，按实际宽度限制为电脑一行、手机两行；
  将已解决和复制链接交由官方“更多”折叠机制收纳，隐藏重复总数。
- 关闭：恢复官方图标、总数和操作按钮展示，包括官方只显示前三种图标的规则。

切换后刷新帖子页面即可看到效果，无需重新构建或重启。此开关只控制显示，
不会关闭 reactions，也不改变“更多表情”、历史反应或计入点赞的规则。

## A/B 部署

将 `deploy/rs-reaction-counts.template.yml` 复制到
`/var/discourse/templates/rs-reaction-counts.template.yml`，并在两个槽位配置中引用：

```yaml
templates:
  - "templates/web.template.yml"
  - "templates/rs-reaction-counts.template.yml"
```

删除原有 reactions 删除、fork 克隆和 package.json 复制命令。
在备用槽位执行 bootstrap 时，模板会从本仓库 `main` 拉取最新补丁，在
`after_code` 阶段检查并应用，然后由正常构建流程编译资源。
验证备用容器健康和页面后，再平滑重载 Nginx 切换流量。
`stylesheet-build-cache.patch` 按样式内容指纹隔离样式链接缓存，防止 A/B
使用同一官方 Git 版本但补丁不同的时候，新容器拿到旧容器的 CSS 链接。

```bash
bash apply.sh /var/www/discourse
```

应用脚本支持重复运行。上游修改导致补丁不兼容时，脚本以非零状态退出，
构建应停止；不会自动猜测修改位置，也不能忽略错误强行发布。
升级以主程序附带的 reactions 为基准，不单独混入其他版本的官方插件。

## 维护和回滚

维护 `patches/` 中的显示和安全补丁。模板不内嵌补丁正文；后续补丁提交到
`main` 后，下次构建自动拉取。已运行的容器不会被 Git 提交自动修改。
在不能访问本仓库的构建环境中，克隆会失败；请通过已有的部署凭据机制
提供只读访问，不要把令牌写进 YAML 或仓库。

旧插件完整历史保留在 Git 中，原生产分支
`discourse_2026.3.0-78c37cfd2b` 保留不变，迁移前的 main 另有
`legacy-plugin-main-before-patch` 分支。旧分支仅供查阅和回滚，不再用于新部署。

2026-10-08：显示补丁已在 Discourse `ee099f4f5acd9624e58228f34c69589728287991`
部署验证，覆盖桌面、390px/320px、单种和八种 reaction、换行、计数、用户菜单。
部署模板的切换不改变已上线的相同补丁内容。

## 禁用表情安全补丁

`patches/reaction-deny-list.patch` 让帖子和聊天 reaction 的写入及读取遵守
`emoji_deny_list`。它不修改 `Emoji.exists?` 的存在性语义，也不硬编码任何禁用表情。
校验覆盖 canonical code、别名、可选冒号以及肤色形式；聊天的 Unicode 输入
先走官方转换，再校验。显示模式开关不会关闭这项安全修复。

- API、服务和模型阻止新增/改成禁用 reaction。
- 已有记录不删除：帖子、主题预载数据、当前用户 reaction、用户列表和活动流、
  聊天消息及用户列表都过滤禁用表情。分页统计同步过滤。
- 已有禁用 reaction 可以撤销或替换为允许的 reaction，但不能重新添加。
- 管理员解除禁用后，尚未撤销的历史记录可以重新显示。
- 不重算历史点赞、徽章等业务数据，不清除 App 离线缓存；客户端重新拉取接口后生效。

应用脚本会先检查所有待应用补丁，再统一应用；任何不兼容都会中止构建。
回归测试在 `test/reaction-deny-list-test.rb`，只允许独立数据库
`river_reaction_security_test` 且 `RIVER_DISPOSABLE=1` 的环境运行。
