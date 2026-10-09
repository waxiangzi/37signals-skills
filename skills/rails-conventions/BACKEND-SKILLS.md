# 后端 Rails 技能：怎么串

同一个仓库里的技能是兄弟目录：`rails-*` + `dhh`（37signals 模式）、`ruby`（纯 Ruby）、`hwc-*` 六件套（Hotwire）、`rails-conventions`（本技能）。互相读取用相对路径 `../<名字>/SKILL.md`。

## 工作流的断口：Rails 技能不会自己到场

如果你同时在用一套通用的「实现 → TDD → 评审」工作流（例如 mattpocock 的 `implement` → `tdd` → `code-review`），**那条链一次都不会加载 Rails 技能**：它的各个技能只互相引用，不认识这里的任何一个。而七个 on-demand 技能都带 `disable-model-invocation: true`，没有 description，**没有任何技能能 fire 它们**。

后果具体是：`tdd` 阶段拿到的测试示例是 TypeScript 的（`jest.mock`），fixtures / `ActiveJob::TestHelper` / 事务回滚那套 Rails 默认值不到场；`code-review` 拿通用的 Fowler smell 评 Rails diff，`dhh` 的 concern / callback 判据不到场。

「任务 → 读哪个技能」这半边在 `rails-best-practices-core` 的 `Read the Specialist Skill` 一节：核心技能一被加载，七个 on-demand 技能的路径就在上下文里。**这里不再重复那张表。**

通用工作流的具体跳点是另一套技能的结构，核心技能不该知道，所以只在这里接：

| 工作流那一跳 | 接什么 | 为什么 |
|---|---|---|
| 实现开工前 | 本技能的「落笔前」 | 名字就是接线，错了静默 |
| 写第一条测试前 | invoke `rails-best-practices-core`，再按它的表读 `rails-testing` | 通用 TDD 的示例不是 Rails；`rails-testing` 的 Coverage Budget 同时就是默认 seam 清单 |
| 实现收工前 | 本技能的**四道门** | 通用工作流常写 "typechecking"，Rails 没有；`zeitwerk:check` 和 `test:system` 通常不在它的清单里 |
| 评审的 Standards 轴 | invoke `rails-best-practices-core`，读 `dhh` | 通用 smell 清单不覆盖 Rails 风格 |

子 agent 更隔绝：它可能跑在独立 worktree 里，看不见你的用户级技能目录。派它之前把该读的文件**路径写进 prompt**。

## 两种入口

技能自己的开关决定走哪个，**当场算**（在技能目录下运行，如 `~/.claude/skills`）：

```bash
for f in */SKILL.md; do
  awk '/^---$/{n++; next} n==1' "$f" | grep -qiE '^disable-model-invocation:[[:space:]]*(true|yes|1|on)[[:space:]]*$' \
    && dirname "$f"
done
```

列出来的是**只有人能打**的：模型这边**直接读文件** `<技能目录>/<名字>/SKILL.md` —— 这个开关只挡 Skill 工具，**不挡 Read**。没列出来的用 Skill 工具 invoke。

**只看 frontmatter，不能对整个文件 `grep -l`。** `rails-best-practices-core` 的正文里写着 `` `disable-model-invocation: true` ``（解释路由表为什么要 Read），整文件 grep 会把这个 model-invocable 的核心技能误报成 human-only，而且没有任何报错。

这条命令目录写错时会**静默返回空**（和「全都可 invoke」长得一模一样）。信它之前先验两件事：输出非空，且 `ls | wc -l` 对得上；再抽一个已知的（如 `dhh`）确认它在列表里。

参照基线（以当场跑出来的为准）：human-only 是 `dhh`、`rails-testing`、`rails-migrations`、`rails-jobs`、`rails-security-multitenancy`、`rails-hotwire-realtime`、`rails-webhooks`。

## 选哪个

Rails 的七个领域（测试 / 迁移 / 任务 / 安全 / Hotwire / webhook / DHH 评审）**不在这里列**，唯一来源是 `rails-best-practices-core`。这里只列它覆盖不到的：

| 何时 | 用哪个 |
|---|---|
| 纯 Ruby（不涉及 Rails） | `ruby` |
| Turbo / Stimulus 的具体交互 | 下面的 `hwc-*`，比 `rails-hotwire-realtime` 专用度更高 |

按问题选一个 `hwc-*`：表单/校验 → `hwc-forms-validation`；导航/分页/懒加载 → `hwc-navigation-content`；WebSocket / Turbo Stream → `hwc-realtime-streaming`；媒体 → `hwc-media-content`；加载态/过渡 → `hwc-ux-feedback`；Stimulus 基础 → `hwc-stimulus-fundamentals`。它们是可直接 invoke 的（没有 `disable-model-invocation`）。

## 纪律

任务命中就先读那个 SKILL.md 再动手 —— 这些技能给的是完整的默认值清单，凭记忆复述只会漏。

## 仓库赢过技能

这些领域技能给的是**默认值**。它们与仓库的 ADR、`CODING_STANDARDS.md`、领域词汇表冲突时，**仓库赢**。

### 分清「观察」和「判据」

`rails-best-practices-core` 自报来源是「distilled from 37signals codebases (Campfire, Fizzy)」—— 也就是**读那两个仓库、看里面有什么**。所以它的 `## Dependencies` 那节（Devise / Pundit / RSpec / FactoryBot / ViewComponent / Redis / Tailwind 列为「它们没用」）是**一张快照**：这些东西的共同点是「那两个仓库里没有」，不是「技术上劣」。

真正的判据只有同节那两个问句：**vanilla Rails 能不能做？50–150 行自写是不是比一个依赖更简单？** 拿判据去算自己项目的账，别抄答案。

同样列在其中的两类性质还不同：Devise / Pundit / service objects 有 vanilla Rails 的等价物（核心技能给了 Pundit 的替代：模型谓词方法 `card.editable_by?(user)`）；而 Tailwind 没有「Rails 内置的 CSS 方案」，替代品是**手写 CSS/SCSS** —— 37signals 为此维护着 `@37signals/stylelint-config-scss`。那是团队能力与审美的取舍（专职设计师、稳定产品线、少数人长期维护 HTML），换个团队这笔账完全不同。

一个算出不同答案的例子：选 Tailwind v4 的理由是 `tailwindcss-rails` 的 **standalone 二进制不需要 Node**，恰好消掉了 37signals 跳过它的成本项之一。同时禁用 Tailwind 最标志的 `dark:` 变体（`dark:` 只看 `prefers-color-scheme`，看不见应用层覆盖，明暗三态需求下是错的），改用 `light-dark()`，并把 Tailwind 降为「设计 token 的**消费者**，不是它们的家」。

**所以读这类清单时先问它是观察还是判据。** 判据跨项目成立，观察只在它被观察的那两个仓库里成立。
