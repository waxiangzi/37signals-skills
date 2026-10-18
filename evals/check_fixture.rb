#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 夹具体检：夹具坏掉的时候，测出来的不是模型，是环境。
# 本会话踩过一次（没有 bin/、Gemfile.lock、Tagging 模型，eager load 也炸），
# 而且是从报告里看不出来的 —— 它只表现为"模型答得变差"。
#
#   ruby evals/check_fixture.rb

require "fileutils"
require "tmpdir"
require "open3"

require_relative "run"

GATES = [
  ["bundle check",                        ["bundle", "check"]],
  ["bin/rails test",                      ["bin/rails", "test"]],
  ["bin/rails zeitwerk:check",            ["bin/rails", "zeitwerk:check"]],
  ["bin/rubocop",                         ["bin/rubocop"]]
].freeze

def main
  workdir = Dir.mktmpdir("fixture-gate-")
  failures = []
  begin
    FileUtils.cp_r(File.join(FIXTURE, "."), workdir)
    init_git(workdir)
    unless system("git", "log", "--oneline", "-1", chdir: workdir, out: File::NULL, err: File::NULL)
      failures << "git log：夹具副本不是 git 仓库（技能要求先 git diff 再评审）"
    end

    GATES.each do |label, cmd|
      out, status = Open3.capture2e(*cmd, chdir: workdir)
      ok = status.success? && !out.match?(/(\d+) errors?[,)]?(?!\D*0)/)
      puts format("  %-28s %s", label, ok ? "✓" : "✗")
      failures << "#{label}：#{out.lines.last(3).join.strip[0, 300]}" unless ok
    end
  ensure
    FileUtils.remove_entry(workdir, true)
  end

  if failures.empty?
    puts "夹具体检通过（#{GATES.size} 道门 + git 仓库）"
    exit 0
  end
  warn "夹具体检失败："
  failures.each { |f| warn "  - #{f}" }
  exit 1
end

main if $PROGRAM_NAME == __FILE__
