# Coding Standards

本文件由 agent 在实现与 review 阶段加载。只写「违反即为 bug」或「违反会被 review 打回」的硬约束，不写主观风格偏好；**能机械化的条目一律去写守卫，再从本表删掉**。

## 工具门（必须全绿）

- `bin/rubocop` —— 0 offense；不要为了迁就代码去新增 disable。
- `bin/rails test` —— 0 failures、**0 errors**（Minitest 分开计数，只找 "failures" 会把红读成绿）。
- `bin/rails zeitwerk:check` —— 全绿（把「只在生产启动时才炸」的路径↔常量错提前到提交前）。
- `bin/rails test:system` —— 有 system 测试就加这一行；**改视图 / Turbo / JS 时必须跑**（它不在 `bin/rails test` 里，Rails 对该任务的描述就是 "except system ones"）。

## 术语

一律使用 `GLOSSARY.md` 的词汇；它列为 _Avoid_ 的同义词一律不用。

## 红线（违反即 bug，且症状静默）

| # | 红线 | 违反后的症状 | 守卫（已点名的 review 免检） |
| --- | --- | --- | --- |
| R1 | | | |

空表出生 —— 每条由复盘（如 mattpocock 的 `/retro`）长出来：症状静默、且机械可查的，直接去写守卫（`test/<主题>_conventions_test.rb`），不必进本表。
