# 技能评估（evals）

在合成 Rails 夹具里无头运行 `claude -p`，测量技能的两个轴：

- **触发**：用了该用的技能吗？（反例 = 不该用时一次都没加载）
- **内容**：回答里出现了技能才会讲的判据吗？（正则断言，`avoid` 可排除）
- **技能增益**：`--arms default,noskills` 跑无技能基线，内容通过率之差。

## 用法

```bash
cd evals
python3 run.py --arms default,noskills --jobs 3 --model cc/deepseek-flash
python3 run.py --only helper-naming --runs 3     # 单用例复跑
python3 -m unittest test_scoring                 # 评分逻辑与用例集自检（不花钱）
```

结果落在 `results/<stamp>.md|.json`（不提交），原始 stream 在 `results/raw/`。

## 设计

- 每个用例在夹具的**一次性副本**里跑（`--permission-mode acceptEdits`，写不到别处）；
  模型写出的新文件会并入内容评分，写文件不贴代码不算失败。
- 环境隔离 = 只看这套技能：`--strict-mcp-config`（关 MCP）、`--setting-sources project`
  （不加载用户级 hooks/权限——否则用户的命令改写 hook 会吃掉 Bash 白名单）、
  `--tools` 白名单 + `--add-dir` 指向仓库 `skills/`。init 里应恰好是仓库里的技能数。
- `noskills` 臂加 `--disable-slash-commands` 关掉全部技能。
- 没有 result 事件的半截回答按**基础设施失败**处理并从汇总剔除（超时会重试 2 次）。
- 期望里含 `disable-model-invocation` 技能的用例记为 `human` 桶：模型不能用 Skill 工具
  加载它们（会被框架拒绝），只能靠 Read 或 `rails-conventions` 的路由发现——两个桶的
  召回分开报。
- `fork HEAD` 记进报告头；改技能前后各跑一次即为 A/B。

## 加一个用例

往 `cases.json` 追加：`id`、`prompt`、`expect_any`（正例）或 `forbid: "ALL"`（反例）、
`checks[].any`（必须命中之一）/`checks[].avoid`（命中即此条失败，修法不带旧词时用）。
`test_scoring` 会校验技能名存在、正则可编译、正反例都在。

## 注意

单次运行有方差（模型自述、措辞波动）；比较结论建议 `--runs 3` 看稳定性。
每个用例约 $0.05–0.7、20–180 秒（取决于模型）。
