# 技能评估（evals）

在合成 Rails 夹具里无头运行 `claude -p`，测量技能的两个轴：

- **触发**：用了该用的技能吗？（反例 = 不该用时一次都没加载）
- **内容**：回答里出现了技能才会讲的判据吗？（正则断言，`avoid` 可排除）
- **技能增益**：`--arms default,noskills` 跑无技能基线，内容通过率之差。

## 用法

```bash
ruby evals/run.rb --arms default,noskills --jobs 3 --model cc/deepseek-flash
ruby evals/run.rb --only helper-naming --runs 3 --model cc/deepseek-flash   # 单用例复跑
ruby evals/run.rb --bucket auto,negative --runs 3 --model cc/glm-5.3-flash  # 只跑不确定的桶
ruby evals/test_run.rb                                                      # 评分逻辑与用例集自检（不花钱）
```

结果落在 `results/<stamp>.md|.json`（不提交），原始 stream 在 `results/raw/`。
报告头记 `fork HEAD`、`claude --version` 与隔离方式 —— 换技能或换 claude 版本前后各跑一次即为 A/B。

## 设计

- 每个用例在夹具的**一次性副本**里跑（`--permission-mode acceptEdits`，写不到别处）；
  模型写出的新文件会并入内容评分，写文件不贴代码不算失败。
- 环境隔离 = 空 `CLAUDE_CONFIG_DIR`（只把 `~/.claude/settings.json` 的 `env` 段带过去）：
  个人技能、插件、个人 CLAUDE.md、用户级 hook（如 rtk，会改写 Bash 命令并压缩输出）都不加载。
  实测技能清单从 81 降到 16（仓库）+ 15（claude 内置）。
- 技能注入 = 把仓库 `skills/` 拷进夹具副本的 `.claude/skills/`（项目技能，init 清单里
  才看得到）；`--add-dir` 指向裸技能目录**不会**注册技能（实测 claude 2.1.285）。
  另：本机 claude 会因未知 frontmatter 键**整个丢弃**该技能，`paths` 即其一，注入时就地剥掉。
- `--strict-mcp-config`（关 MCP）、`--tools` 白名单、`--allowedTools` 放行只读 Bash、
  跑夹具自己的门（`bin/rails test` / `zeitwerk:check` / `rubocop` / `bundle` / `gem`）、
  以及 `Skill`（否则 Skill 调用被拒）。两臂都不 `--add-dir`。
- `noskills` 臂加 `--disable-slash-commands` 关掉全部技能，且不注入技能。
- 注入的 `.claude/` 不计入产出物（否则技能正文会污染内容评分）。
- **触发只算加载成功**：被权限拒/报错的 Skill 调用、没拿到结果的调用都不计（否则白送分）。
- 没有 result 事件的半截回答按**基础设施失败**处理并从汇总剔除（超时会重试 2 次）。
- 期望里含 `disable-model-invocation` 技能的用例记为 `human` 桶：模型不能用 Skill 工具
  加载它们（会被框架拒绝），只能靠 Read 或 `rails-conventions` 的路由发现——两个桶的
  召回分开报。
- 夹具是**能跑起来的** Rails 8 应用（`bin/rails test` / `zeitwerk:check` / `rubocop` 全绿，
  gems 用本机已装的，sqlite3 数据库按需生成）：技能要求「先跑探针再断言」的那部分才有东西可跑。
- 复合命令（`&&`、`;`）、`$VAR` 展开会被权限系统拒（`subcommandResults` / `simple_expansion`），
  写在夹具外的文件同理。这是有意的：拒绝量本身是一个可观测信号，模型得自己拆成单条重试。
- 内容通过率只统计**正例**：反例的内容断言（“GIL 是什么”）谁都能答对，混进去会系统抬高增益。

## 统计口径

单轮有方差（模型措辞、`fired` 计数在 n=8/5 的桶里能被一轮翻转），所以：

- 结论只看**桶**（auto / human / 反例），不看单条用例的 ✓✗；
- 需要下结论的桶跑 `--runs 3`：`--bucket auto,negative --runs 3` 覆盖不确定的部分，
  比全量三轮便宜一半以上；
- 内容轴同理：每条 `checks` 的通过率要按 n=3 看，单轮的全绿可能是天花板（基座本来就会）。

## 加一个用例

往 `cases.json` 追加：`id`、`prompt`、`expect_any`（正例）或 `forbid: "ALL"`（反例）、
`checks[].any`（必须命中之一）/`checks[].avoid`（命中即此条失败，修法不带旧词时用）。
`test_run.rb` 会校验技能名存在、正则可编译、正反例都在。

**内容断言要有判别力**：基座模型不加载技能也照答的断言（例如"提到 `_helper` 后缀"）
不测任何东西 —— 先跑 `--arms noskills --runs 3` 预筛，通过率 ≥ 90% 的断言要么删，
要么换成技能里真正反直觉的那条（框架静默失败、`after_commit` 才清状态、门住在 gem 里……）。

## 注意

每个用例约 $0.15–1.0、30–240 秒（取决于模型；夹具能跑门之后探针变多）。
