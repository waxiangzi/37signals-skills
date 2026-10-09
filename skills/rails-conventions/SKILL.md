---
name: rails-conventions
description: >-
  Rails conventions the framework enforces by silence — the name IS the wiring, so
  a mismatch never raises; it just fails to connect, then explodes somewhere
  unrelated. Reach for this before creating or renaming anything under app/, before
  adding a method to a helper, before a migration or job, before hand-writing a
  guard or probe, before diffing rendered HTML, and before committing Rails code.
  Carries the pre-commit gates (including the one `bin/rails test` silently
  excludes), the 30-second `bin/rails runner` probes that beat inference, two-sided
  verification for your own guards, and the wiring that a generic
  implement/tdd/code-review workflow leaves unconnected in a Rails repo — those
  domain skills cannot fire themselves.
paths:
  - "app/**"
  - "config/**"
  - "db/**"
  - "test/**"
  - "lib/**/*.rb"
  - "Gemfile"
  - "config.ru"
allowed-tools:
  - Bash(bin/rails runner:*)
  - Bash(bin/rails zeitwerk:check)
  - Bash(bin/rails test:*)
  - Bash(bin/rubocop:*)
  - Bash(ruby -e:*)
---

# Rails Conventions

Rails 里有一类约定是**接线**：名字本身就是连接方式。接错了，框架**不报错** —— 它只是不接上，然后在别处炸，栈指向的地方离原因很远。

## 落笔前

### 名字就是接线

在 `app/` 下新建或改名文件之前，先确认它在框架眼里**叫什么**：

| 位置 | 文件名 | 常量名 | 接错时的症状 |
|---|---|---|---|
| `app/helpers/` | `<name>_helper.rb` | `<Name>Helper` | **静默** —— 收录只扫 `**/*_helper.rb`，切掉后缀再拼回 `Helper` 求常量；名字不匹配的文件干脆不被收录，视图里才报 `undefined method`，栈指向调用点 |
| `app/` 其它 | Zeitwerk 的路径规则 | 见下 | **响亮** —— 启动时 `NameError: uninitialized constant` |

**两条探针都要跑，先跑再落笔。** 它们管的不是同一件事：

```bash
RAILS_ENV=test bin/rails zeitwerk:check   # 路径 ↔ 常量（会强制 eager load）
```

```bash
RAILS_ENV=test bin/rails runner '
root = Rails.root.join("app/helpers").to_s
names = ActionController::Base.all_helpers_from_path([root])
p Dir["#{root}/**/*.rb"].reject { |f| names.include?(f.sub("#{root}/", "").sub(/_helper\.rb\z/, "")) }'
```

**helper 的收录不归 `zeitwerk:check` 管** —— 一个名字错的 helper 可以让 `zeitwerk:check` 全绿，同时根本没被收录。

**做完的标准**：`zeitwerk:check` 全绿，`runner` 返回空数组，且这一票新建或改名的**每个**文件你都能在第二条的 `names` 里点名找到。三条都对才算确认完。

票面、设计文档、issue 标题里点名的模块名是**假设**。它与框架的接线冲突时，在写码之前提出来 —— 改一个名字，比改完 12 个调用点再回来改名字便宜得多。

### 视图上下文是共享命名空间

helper 模块 include 进视图上下文后，会盖掉 ActionView 自己的方法，**私有方法也算**。接错时炸的是**无关调用方**（`form.hidden_field`、`text_field_tag` 报 `wrong number of arguments`），你新写的那几个调用点看起来毫无问题。

```ruby
av = ActionView::Base.instance_methods + ActionView::Base.private_instance_methods
av.include?(:field_id)   # => true：FormTagHelper 的私有方法，占着这个名字
```

### 最小冒烟先于铺开

新建文件、改方法签名之后，先让**一个**视图或**一条**测试跑通，再改 N 个调用点。反过来就是 N 倍的返工。

## 探针：`bin/rails runner`

「这个 API 到底怎么工作」几乎总能在 30 秒内答出来，比推断可靠：

```bash
RAILS_ENV=test bin/rails runner 'p Post.listing.first.attributes.keys'
```

`RAILS_ENV=test` 是必需的：漏了它会连到开发库，或者拿到一个与测试完全不同的世界。

框架与 gem 的行为，**读源码**比搜索可靠 —— 版本对不上时尤其如此：

```bash
ruby -e 'puts Gem::Specification.find_by_name("actionpack").gem_dir'
```

## 收笔前：四道门

```bash
bin/rubocop                 # 0 offense
bin/rails test              # 0 failures 且 0 errors —— 两个都要看
bin/rails zeitwerk:check    # 全绿
bin/rails test:system       # 有 test/system/ 就跑；改视图 / Turbo / JS 必跑
```

`0 errors` 要单独盯。Minitest 把 errors 和 failures **分开计数**，摘要长这样 —— `10 runs, 20 assertions, 0 failures, 1 error`。只找 "failures" 的人（和 agent）会把红读成绿。

**第四道容易漏，因为前三道看起来已经跑完了测试。** `bin/rails test` 的官方描述逐字是 "Run all tests in test folder **except system ones**" —— Turbo frame 导航、Stimulus 交互、明暗切换只有 `test:system` 看得到。

「这台机器跑不了 system 测试」是**待验证的假设**，当场跑一次就有答案。一次失败说明的是这次失败：这条二手结论曾被原样写进三个派发 prompt，补齐无头 Chrome 依赖后实测 12 秒全绿。

### 这四道门在仓库里**也**要有一份

本技能住在 `~/.claude/skills/`，**容器里的 agent 看不见它** —— 无人链路（Sandcastle 之类）只 bind-mount git worktree，个人 skills 目录不在挂载里。那条链路唯一能拿到的副本是仓库内的 `CODING_STANDARDS.md`。

所以**仓库里那份工具门不是重复，是另一条链路的唯一来源**。两份都留，各自维护 —— 合并掉会让无人链路静默失去四道门：票照过，门没跑，没有任何提示。

### 有些门住在框架里

判断「这个风险有没有人管」，**先问框架**。Rails 自带一批启动期检查，它们住在 gem 里而不是仓库里 —— grep 看不见，却确确实实在拦：

| 风险 | 门在哪 | 症状 |
|---|---|---|
| 迁移写了没跑 | `ActiveRecord::Migration.maintain_test_schema!`（内部 `check_pending_migrations`） | `bin/rails test` 退出码 1，并**点名那个迁移文件** |
| path ↔ 常量错位 | `bin/rails zeitwerk:check` | 跳过它，就只在**生产启动**时才炸 |

`grep 仓库 → 没找到 → 断言没有门` 是错的推理。顺着它补一条更弱的自写守卫，造出来的是**假的门** —— 比没有门更坏：它让人以为这件事有人管，从此不再检查。

### 自己写的守卫和探针，必须过非空验证

**故意造出它该抓的坏输入，看它真的打红、且信息点名。** 做不到，说明它是装饰。

**两向都要验。** 负控只证明「它响了」，不证明「它还在看」。「`Dir[...]` / 常量列表挑一批文件 → `assert_empty(命中)`」这类**扫描型守卫**，在扫描集为空时（glob 写错、目录改名、常量改错）看到的正是「负控全绿、什么都没看」的一幕 —— 而且它报的是平安。所以每条扫描型守卫再配一条**正控**：扫描集非空，且匹配器 / 检测器对**合成坏样本**真的报红。验证正控本身的办法：把扫描路径临时改坏，负控应保持全绿、正控应真红。

上面「找没被收录的 helper」那个 `runner` 片段同理：先用一个**故意命名错的**文件验一次，确认它真的出现在输出里。一个恒返回 `[]` 的探针，和一个「全部收录」的世界，长得一模一样。

## 机械守卫：静默陷阱的家

**判据**：违反之后**没有任何运行时反馈**（跨文件一致性、命名约定、部署配置、响应头、查询列）→ 写一条守卫测试。症状响亮的（启动就炸、一跑就红）不需要守卫。

三个通用样本，换项目多半还会遇到：

| 陷阱 | 症状（静默） | 守卫形态 |
|---|---|---|
| HTML 响应带 `Cache-Control: public` 或正 `max-age` | 反向代理 / Thruster 据此整页缓存、剥 `Set-Cookie`、命中时绕过应用；Turbo 分不清 frame 片段与整页（两者共用一个 URL） | 一条共享断言（`refute_match(/(?:\A\|[\s,])public(?:[\s,]\|\z)/)`；每个 `max-age` ≤ 0），各集成测试对页面响应调用一次 |
| 列表查询取回大列（正文 / 长文本） | 列表页每次读整表最大的列；不报错，只是慢 | 投影收进一个 scope（唯一落点）；守卫断言「访问被剔掉的列抛 `MissingAttributeError`」；要钉 SQL 用 `capture_sql`（订阅 `sql.active_record` 收语句再断言） |
| test 环境 `config.cache_store` 不是 `:memory_store` | 限流（`rate_limit`）永不触发，相关测试**永远绿** | 限流测试自证会红：断言「第 N+1 次被拒」，而不只是「前 N 次通过」 |

**形态约定**：放 `test/<主题>_conventions_test.rb`；**只钉事实，不碰渲染**；文件头写清「为什么值得一条测试」（症状是怎么静默的）；断言消息点名 offender 与依据。验证方式（先问框架、非空验证、正控）见上两节。

## 新项目起手

新的 Rails 项目直接拷同目录的 `CODING_STANDARDS.template.md` 起步。**红线只在复盘后长出来** —— 空表出生，每条都得有一次真实事故垫背（mattpocock 的 `/retro` 就是这个流程）；通用规则留在本技能里。文件放仓库根，或放无人链路读取的目录（如 `.sandcastle/`），但要在 `CLAUDE.md` / `AGENTS.md` 留一行指针。

## 服务端渲染默认是不确定的

比对两次渲染（旧态/新态、golden file、逐字节 diff）之前，先归一化：

| 噪声源 | 例子 |
|---|---|
| 时钟 | `Time.current`、`updated_at`（JSON-LD 的 `dateModified`）、自动填的 `published_at` |
| 签名 token | `message_verifier.generate(Time.current.to_i)` —— 每次渲染都重新签 |
| 随机后缀 | 草稿每次编辑重生成的 slug（`post-<8 位 hex>`） |

再加一道**护栏**：证明两次跑的是你想比的那两版代码（例如断言旧版跑时新符号的 `defined?` 为 `nil`）。少了它，「逐字节相同」可能只是两边都没跑到那一段。

## 后端 Rails 技能

写测试、迁移、后台任务、安全边界、Turbo/Stimulus、webhook、纯 Ruby、DHH 风格评审 —— 这些领域各有一个装好的技能，给的是完整默认值清单，凭记忆复述只会漏。

**它们不会自己到场。** 七个 Rails 技能都是 `disable-model-invocation: true`，没有 description，所以 `implement` → `tdd` → `code-review` 那条链一次都不会加载它们 —— `tdd` 阶段看到的测试示例是 TypeScript 的。

跑那条链、或自己写 Rails 代码时，哪一跳该接哪个、怎么打（一部分只有人能 invoke，模型这边直接 Read）、以及**仓库的 ADR 赢过技能的默认值**：读同目录的 `BACKEND-SKILLS.md`。
