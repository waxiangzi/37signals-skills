#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 看每条内容断言的通过率：预筛（`--arms noskills --runs 3`）后就知道哪些断言没有判别力。
#
#   ruby evals/check_rates.rb results/<stamp>.json                  # 默认看全部臂
#   ruby evals/check_rates.rb results/<stamp>.json --arm noskills
#   ruby evals/check_rates.rb results/<stamp>.json --dead 0.9       # 只列 ≥90% 的死断言
#
# 判据：基座模型（无技能）也通过的断言测不出技能增益。要么删，要么换成技能里更反直觉的那条。

require "json"

path = ARGV[0] or abort "用法：check_rates.rb results/<stamp>.json [--arm X] [--dead 0.9]"
arm = (ARGV.index("--arm") && ARGV[ARGV.index("--arm") + 1]) || nil
dead_at = ((ARGV.index("--dead") && ARGV[ARGV.index("--dead") + 1]) || 0.9).to_f
data = JSON.parse(File.read(path))

by_case = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [0, 0] } } # case -> check -> [pass, n]
data["results"].each do |r|
  next if r["score"].nil?
  next if arm && r["arm"] != arm
  r["score"]["checks"].each do |c|
    slot = by_case[r["case"]][c["name"]]
    slot[0] += 1 if c["pass"]
    slot[1] += 1
  end
end

rows = by_case.flat_map do |c, checks|
  checks.map { |name, (pass, n)| [c, name, pass, n, n.positive? ? pass.to_f / n : 0.0] }
end
puts "# 内容断言通过率（#{File.basename(path)}#{arm ? "，臂 #{arm}" : ''}）"
rows.sort_by { |r| [-r[4], r[0]] }.each do |c, name, pass, n, rate|
  puts format("%5.0f%%  %-24s %-46s %d/%d", rate * 100, c, name, pass, n)
end
dead = rows.select { |r| r[4] >= dead_at }
never = rows.select { |r| r[2].zero? }
puts "\n== 死断言（≥#{format('%.0f%%', dead_at * 100)}，无判别力）：#{dead.size} 条"
dead.each { |c, name, _, n, rate| puts format("  %-24s %-46s %d/%d", c, name, (rate * n).round, n) }
puts "\n== 一次都没过（0%，太严或措辞对不上）：#{never.size} 条"
never.each { |c, name, _, n, _| puts format("  %-24s %-46s 0/%d", c, name, n) }
