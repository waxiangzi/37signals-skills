#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 把几轮结果并排放，一屏看两个模型/两个臂的差异。
#
#   ruby evals/compare.rb results/20261016-091442-cc-deepseek-flash.json \
#                         results/20261016-091442-cc-glm-5.3-flash.json
#
# 同一模型的 noskills 基线可以是另一个 --rescore 出来的 json，一并传进来即可。

require "json"

require_relative "run"

files = ARGV.reject { |a| a.start_with?("--") }
abort "用法：compare.rb <results.json> [<results.json> ...]" if files.empty?

def label_of(path, data)
  stamp = File.basename(path, ".json").sub(".rescore", "")
  model = data["model"].to_s.empty? ? stamp.split("-").last(2).join("-") : data["model"]
  "#{model}#{path.include?('rescore') ? '(重打分)' : ''}"
end

rows = []
files.each do |path|
  data = JSON.parse(File.read(path))
  data["results"].group_by { |r| r["arm"] }.sort.each do |arm, rs|
    agg = aggregate(rs)
    pos = rs.select { |r| r["score"] && r["score"]["trigger_kind"] == "positive" }
    count = lambda do |bucket|
      xs = rs.select { |r| r["score"] && r["score"]["trigger_kind"] == "positive" && r["bucket"] == bucket }
      [xs.count { |r| r["score"]["trigger"] }, xs.size]
    end
    auto = count.call("auto")
    human = count.call("human")
    rows << {
      label: label_of(path, data), arm: arm, n: agg["n"], errors: agg["errors"],
      auto: auto, human: human,
      false_trigger: agg["false_trigger_rate"], content: agg["content"],
      behavior: agg["behavior"], composite: agg["composite"], cost: agg["cost"],
      truncated: rs.count { |r| r["truncated"] },
      pos_content: pos.count { |r| r["score"]["content"] }
    }
  end
end

puts "| 模型 | 臂 | 有效/失败 | 召回 auto | 召回 human | 误触发 | 内容(正例) | 行为 | 综合 | 截断 | $ |"
puts "|---|---|---|---|---|---|---|---|---|---|---|"
rows.each do |r|
  fmt = ->(a, b) { b.zero? ? "-" : "#{a}/#{b} #{format('%.0f%%', 100.0 * a / b)}" }
  puts format("| %s | %s | %d/%d | %s | %s | %s | %s | %s | %s | %d | %.2f |",
              r[:label], r[:arm], r[:n], r[:errors],
              fmt.call(*r[:auto]), fmt.call(*r[:human]),
              pct(r[:false_trigger]), pct(r[:content]), pct(r[:behavior]), pct(r[:composite]),
              r[:truncated], r[:cost])
end

puts "\n内容通过率只统计有断言的用例（预筛剪枝后剩下的判别型断言）；行为轴只看技能规定动作是否真做了。"
