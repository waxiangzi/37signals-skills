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

VALUE_OPTS = %w[--arm --bucket].freeze

# 参数解析：带值的选项吃掉下一个 token，其余 --flag 跳过，剩下的才是文件。
files = []
i = 0
while i < ARGV.size
  if VALUE_OPTS.include?(ARGV[i]) then i += 2
  elsif ARGV[i].start_with?("--") then i += 1
  else files << ARGV[i]; i += 1
  end
end
opts = Hash.new { |h, k| h[k] = [] }
ARGV.each_with_index { |a, j| opts[a] = ARGV[j + 1].to_s.split(",") if VALUE_OPTS.include?(a) }

abort "用法：compare.rb <results.json> [...] [--arm default] [--bucket auto,human] [--by-case]" if files.empty?
ARMS = opts["--arm"]
BUCKETS = opts["--bucket"]
BY_CASE = ARGV.include?("--by-case")

# 手写这段表已经写错过一次（忘了按臂过滤，数出 4 个轮次标记），所以做成选项。
def keep?(r)
  (ARMS.empty? || ARMS.include?(r["arm"])) && (BUCKETS.empty? || BUCKETS.include?(r["bucket"]))
end

def label_of(path, data)
  stamp = File.basename(path, ".json").sub(".rescore", "")
  model = data["model"].to_s.empty? ? stamp.split("-").last(2).join("-") : data["model"]
  "#{model}#{path.include?('rescore') ? '(重打分)' : ''}"
end

rows = []
files.each do |path|
  data = JSON.parse(File.read(path))
  data["results"].select { |r| keep?(r) }.group_by { |r| r["arm"] }.sort.each do |arm, rs|
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

if BY_CASE
  puts "\n### 按用例并排（触发 n/N，内容 x/y）"
  labels = files.map { |f| File.basename(f, ".json").sub(".rescore", "").sub(/^\d{8}-\d{6}-/, "") }
  puts "| 用例 | #{labels.join(' | ')} |"
  puts "|---|#{'---|' * files.size}"
  all = files.flat_map { |f| JSON.parse(File.read(f))["results"].select { |r| keep?(r) }.map { |r| r["case"] } }.uniq.sort
  all.each do |cid|
    row = "| #{cid} "
    files.each do |f|
      rs = JSON.parse(File.read(f))["results"].select { |r| keep?(r) && r["case"] == cid && r["score"] }
      chk = rs.flat_map { |r| r["score"]["checks"] }
      trig = rs.empty? ? "-" : "#{rs.count { |r| r["score"]["trigger"] }}/#{rs.size}"
      row += "| #{trig} #{chk.empty? ? '-' : "#{chk.count { |c| c['pass'] }}/#{chk.size}"} "
    end
    puts row + "|"
  end
end
