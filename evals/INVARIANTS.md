# 测量不变量

这个目录产出的每一个数字，都必须满足下面每条。违反的症状几乎都不是"报错"，而是**看起来像模型变差**——本会话三次踩坑都是这个形状。改动 `run.rb` / `cases.json` / 夹具之前先读这一页。

| 不变量 | 违反时的症状 | 谁在兜住它 |
|---|---|---|
| 技能只有拷进夹具副本的 `.claude/skills/` 才会注册 | 报告里技能存在，实际一次都没加载 | `self_check` 比对 `init_skills` |
| 空 `CLAUDE_CONFIG_DIR`：个人技能/插件/hook 不进上下文 | 个人技能抢走触发；hook 改写命令与输出 | `self_check`（noskills 臂不该有技能） |
| 未知 frontmatter 键会整个丢掉技能（`paths` 是其一） | 某个技能对所有人不可见 | `stage_skills` + `self_check` |
| 触发只算**加载成功**的技能 | 召回被高估（被拒的调用也算分） | `parse_stream` 配 `tool_result` + `skill_denied` 计数 |
| 网关错误走 success 通道回来 | 401 被当成"模型答得很差"，整批数字作废 | `run_failed?` 认 `is_error`/`api_error_status` + `self_check` 比例 |
| 每轮一个 raw 文件，文件名带轮次 | `--runs 3` 覆盖前几轮，无法重打分 | `raw_name` + `self_check` 查重复/缺失 |
| 内容断言要有判别力（无技能也要答对的断言等于没测） | 内容轴顶到天花板，增益 ≈ 0 | `--prescreen` + `check_rates.rb` |
| 夹具必须真能跑（`bin/rails test` / `zeitwerk:check` / `rubocop` / git） | 技能规定的动作无从执行，读作模型不听话 | `evals/check_fixture.rb` |
| 数字必须能追溯到 `results/raw/<stamp>/` | 改断言后只能重跑（花钱），或结论不可复核 | `--rescore` |
| 反例的内容断言不参与内容通过率 | 增益被"谁都能答对"的题抬高 | `aggregate` 只取正例 |

## 一条命令

```bash
./bin/check                 # 自检 + 夹具体检（改动 evals/ 或 skills/ 之后）
./bin/check --fast          # 只跑自检
```

批次跑完报告末尾会有 `## 批次自检` 段：`⛔` 是硬伤（原始 stream 缺失/重复、init 技能缺失、基础设施失败 >20%），退出码 2；`⚠` 是警告。
