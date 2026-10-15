# Blog

一个最小的 Rails 8 博客，用作技能评估的合成夹具。它**能真正跑起来**：gems 在本机已装，
`bundle check` / `bin/rails test` / `bin/rails runner` 都可用（DB 用 sqlite3，`storage/` 下自动建）。

```bash
bundle check                 # 依赖齐全
bin/rails db:prepare         # 建库 + 载入 db/schema.rb
bin/rails test               # 单元/集成测试（不含 test/system）
bin/rails zeitwerk:check     # 自动加载检查
```

评估运行时夹具会被整体拷到临时目录，模型在里面读写，所以这里不需要保持干净。
