#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 技能评估：在合成 Rails 夹具的一次性副本里无头跑 `claude -p`，测量技能的两个轴。
# 原来的 Python 版本（run.py）已由本文件取代；行为以 README 的「设计」节为准。
#
#   ruby evals/run.rb --arms default,noskills --jobs 3 --model cc/deepseek-flash
#   ruby evals/run.rb --only helper-naming --runs 3 --model cc/deepseek-flash
#   ruby evals/test_run.rb          # 评分逻辑与用例集自检（不调用模型）

require "fileutils"
require "json"
require "optparse"
require "shellwords"
require "stringio"
require "time"
require "timeout"
require "tmpdir"
require "zlib"

EVALS = File.expand_path(__dir__)
REPO = File.expand_path("..", EVALS)
CASES = File.join(EVALS, "cases.json")
FIXTURE = File.join(EVALS, "fixture")
RESULTS = File.join(EVALS, "results")

TOOLS = "Read,Grep,Glob,Skill,Bash,Write,Edit"

# 技能正文要求先跑探针；工作目录是一次性夹具副本，Bash 只放行只读与一次性求值的命令，
# 外加跑夹具自己的门（bin/rails test / zeitwerk:check / rubocop / bundle / gem）。
READONLY = [
  "ruby -e:*", "python3 -c:*", "node -e:*", "grep:*", "ls:*", "find:*",
  "cat:*", "head:*", "tail:*", "wc:*", "git status:*", "git diff:*", "git log:*",
  "git -C:*", "bin/rails:*", "bin/rake:*", "rails:*", "bundle:*", "gem:*", "which:*"
].freeze
# 用户级 hook 会把命令改写成 `rtk <子命令>`；隔离生效时它不该出现，保留只是防回归。
BASH_ALLOW = READONLY.map { |p| "Bash(#{p})" } + ["Bash(rtk:*)", "Bash(echo:*)", "Skill"]

# 本机 claude 会因未知 frontmatter 键整个丢弃技能（`paths` 即是）；注入副本时剥掉。
SKILL_FM_DROP = ["paths"].freeze

RETRIES = 2
ABORT_SAME_ERROR = 3   # 同一错误签名重复到这个次数
ABORT_WINDOW = 12      # 且还发生在前 N 轮之内 —— 一次事故不该烧掉整批
ARTIFACT_CAP = 20_000
ANSWER_CAP = 60_000
SKIP_ARTIFACT_DIRS = [".git", ".claude", "node_modules", "tmp", "log"].freeze

# ---------------------------------------------------------------- 配置 / 元数据

def known_skills
  Dir[File.join(REPO, "skills", "*", "SKILL.md")].map { |p| File.basename(File.dirname(p)) }.sort
end

# name -> 是否可被模型自动调用（frontmatter 里的 disable-model-invocation）
def skill_meta
  meta = {}
  Dir[File.join(REPO, "skills", "*", "SKILL.md")].each do |p|
    text = File.read(p, encoding: "UTF-8")
    fm = text[/\A---\s*\n(.*?)\n---/m, 1].to_s
    meta[File.basename(File.dirname(p))] = !fm.match?(/^disable-model-invocation:\s*(true|yes|1|on)\s*$/i)
  end
  meta
end

def normalize_skill(name)
  name.to_s.split(":").last
end

# 用例期望的技能里有没有可自动调用的；没有 = 只能靠路由/人工发现
def case_bucket(kase, meta)
  names = kase["expect_any"] || []
  return nil if names.empty?
  names.any? { |n| meta[n] } ? "auto" : "human"
end

# 空配置目录：不带个人技能/插件/用户级 hook（rtk 会改写 Bash 命令并压缩输出）。
# 只把 ~/.claude/settings.json 的 env 段（网关地址/令牌）带过去。
def make_cc_config
  cfg = Dir.mktmpdir("skilleval-cc-")
  src = File.join(Dir.home, ".claude", "settings.json")
  env = {}
  if File.exist?(src)
    env = (JSON.parse(File.read(src))["env"] || {}) rescue {}
  end
  File.write(File.join(cfg, "settings.json"), JSON.pretty_generate({ "env" => env }))
  cfg
end

def claude_version
  out = IO.popen(["claude", "--version"], err: [:child, :out], &:read).to_s
  line = out.strip.lines.first
  line ? line.strip : "?"
rescue SystemCallError
  "?"
end

# 批次健康：跑的过程中看一眼，别等跑完才发现整批都被同一件事废掉了
# （20261018 那批 61 轮里 21 轮是网关 401，$20 白烧）。
class BatchHealth
  attr_reader :mutex, :signatures

  def initialize
    @mutex = Mutex.new
    @done = 0
    @fails = 0
    @signatures = {}
    @abort_reason = nil
  end

  def record(ok:, signature: nil)
    mutex.synchronize do
      @done += 1
      if !ok && signature
        @signatures[signature] = @signatures[signature].to_i + 1
        hit = @signatures.find { |_, n| n >= ABORT_SAME_ERROR && @done <= ABORT_WINDOW }
        @abort_reason ||= "同一错误重复 #{hit[1]} 次：#{hit[0]}" if hit
      end
      @fails += 1 unless ok
    end
  end

  def aborted? = mutex.synchronize { !@abort_reason.nil? }
  def snapshot = mutex.synchronize { { done: @done, fails: @fails, abort: @abort_reason } }
end

# 原始 stream 的文件名（归一到一个地方，重打分与自检都靠它）
def raw_name(arm, case_id, run_no)
  [arm, case_id, "r#{run_no}"].join("--") + ".jsonl.gz"
end

def raw_parts(basename)
  stem = basename.sub(/\.jsonl\.gz\z/, "")
  parts = stem.split("--")
  run_no = parts.last.to_s.match?(/\Ar\d+\z/) ? parts.pop.delete_prefix("r").to_i : 1
  [parts[0], parts[1], run_no]
end

# ---------------------------------------------------------------- 事件流解析

# 从 stream-json 事件里提取：**加载成功**的技能、回答文本、成本、轮数、被拒的工具。
#
# 失败的调用不算加载：被权限拒的 Skill 调用、报错的 Read 都拿不到技能正文，
# 计成 fired 会白送一分（历史上 mac 轮没放行 Skill，系统性高估就在这里）。
def parse_stream(lines)
  pending = {}   # tool_use_id -> skill 名
  pending_write = {} # tool_use_id -> 写文件的内容（供重打分用）
  loaded = []
  writes = []
  result_error = false
  api_error_status = nil
  init_skills = nil
  skill_denied = 0
  pending_skill = {}
  commands = [] # 模型实际跑过的 Bash 命令（行为轴）
  reads = []    # 模型实际读过的文件（行为轴：评审类用例要求“先看了再评”）
  texts = []
  denied = []
  cost = 0.0
  turns = 0
  result_text = nil
  ended = nil

  lines.each do |line|
    line = line.strip
    next unless line.start_with?("{")
    begin
      ev = JSON.parse(line)
    rescue JSON::ParserError
      next
    end

    case ev["type"]
    when "assistant"
      Array(ev.dig("message", "content")).each do |block|
        if block["type"] == "text"
          texts << block["text"]
        elsif block["type"] == "tool_use"
          inp = block["input"] || {}
          name =
            if block["name"] == "Skill" && inp["skill"]
              normalize_skill(inp["skill"])
            elsif block["name"] == "Read"
              inp["file_path"].to_s[%r{/([^/]+)/SKILL\.md\z}, 1]
            end
          next unless name
          pending[block["id"].to_s] = name
          pending_skill[block["id"].to_s] = name
          body = case block["name"]
                 when "Write" then inp["content"]
                 when "Edit" then inp["new_string"]
                 when "MultiEdit" then Array(inp["edits"]).map { |e| e["new_string"] }.join("\n")
                 end
          pending_write[block["id"].to_s] = [inp["file_path"], body] if body
          commands << inp["command"] if block["name"] == "Bash" && inp["command"]
          reads << inp["file_path"].to_s if block["name"] == "Read" && inp["file_path"]
        end
      end
    when "user"
      Array(ev.dig("message", "content")).each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_result"
        tid = block["tool_use_id"].to_s
        name = pending.delete(tid)
        pending_skill.delete(tid)
        loaded << name if name && !block["is_error"]
        # 模型写出的文件正文也在事件流里：存下来，这样改断言后能照原样重打分
        file, body = pending_write.delete(tid)
        writes << "--- #{file} ---\n#{body}" if file && body && !block["is_error"]
      end
    when "system"
      if ev["subtype"] == "init"
        init_skills = ev["skills"] || []
      elsif ev["subtype"] == "permission_denied"
        denied << (ev["tool_name"] || ev.dig("tool", "name") || "?")
      end
    when "result"
      cost = ev["total_cost_usd"].to_f
      turns = ev["num_turns"].to_i
      result_text = ev["result"]
      ended = ev["subtype"]
      result_error = ev["is_error"] ? true : false
      api_error_status = ev["api_error_status"]
    end
  end

  # 调了但没成功拿到正文的技能：这些不算触发，但数量本身是信号（触发轴高估的来源）
  skill_denied = pending_skill.size

  answer = texts.join("\n")
  answer += "\n#{result_text}" if result_text && !answer.include?(result_text)
  { "fired" => loaded.uniq.sort, "answer" => answer, "cost" => cost, "turns" => turns,
    "denied" => denied, "ended" => ended, "writes" => writes, "commands" => commands,
    "reads" => reads, "result_error" => result_error, "api_error_status" => api_error_status,
    "init_skills" => init_skills, "skill_denied" => skill_denied }
end

# 没有 result 事件（超时/崩溃）或没有回答 = 基础设施失败，不是数据。
#
# 网关把凭据/额度一类的错误塞进正文返回时，subtype 照样是 success、cost 是 0，
# 只有 is_error / api_error_status 说实话 —— 不认这两个字段，401 会被当成一次
# "模型答得很差"计进分数（20261018-160032 那批 61 轮里有 21 轮就是这么被污染的）。
def run_failed?(parsed)
  return true if parsed["ended"].nil? || parsed["answer"].to_s.strip.empty?
  return true if parsed["result_error"] || parsed["api_error_status"]
  parsed["answer"].match?(/\AFailed to authenticate|API Key has been disabled|\AAPI Error: \d{3}/i)
end

# ---------------------------------------------------------------- 评分

# 行为轴：expect_tools 每条要求至少有一条实际跑过的命令（或写出的文件路径）命中它。
def behaviors_for(kase, commands, writes = [])
  hay = Array(commands) + Array(writes)
  Array(kase["expect_tools"]).map do |b|
    hit = hay.any? { |c| Array(b["cmd"]).any? { |p| c.to_s.match?(Regexp.new(p, Regexp::IGNORECASE)) } }
    { "name" => b["name"], "pass" => hit }
  end
end

def score_case(kase, answer, parsed, known)
  fired = parsed["fired"] & known
  if kase["forbid"] == "ALL"
    trigger = fired.empty?
    trigger_kind = "negative"
  else
    trigger = !(fired & Array(kase["expect_any"])).empty?
    trigger_kind = "positive"
  end

  checks = Array(kase["checks"]).map do |check|
    found = ->(pats) { Array(pats).any? { |p| answer.match?(Regexp.new(p, Regexp::IGNORECASE)) } }
    hit = found.call(check["any"]) && !found.call(check["avoid"])
    { "name" => check["name"], "pass" => hit }
  end

  # 行为轴：技能除了“能说对”之外，还要求“真去跑”。比内容轴难造假得多。
  behaviors = behaviors_for(kase, parsed["commands"],
                            Array(parsed["writes"]) + Array(parsed["reads"]))

  passed = checks.count { |c| c["pass"] }
  beh_passed = behaviors.count { |b| b["pass"] }
  { "trigger_kind" => trigger_kind, "trigger" => trigger, "fired" => fired.sort,
    "checks" => checks, "content" => checks.empty? ? nil : passed.to_f / checks.size,
    "behaviors" => behaviors,
    "behavior" => behaviors.empty? ? nil : beh_passed.to_f / behaviors.size }
end

# ---------------------------------------------------------------- 夹具

# 把仓库技能作为项目技能注进夹具副本的 .claude/skills/。
#
# 裸技能目录（`--add-dir REPO/skills`）在当前 claude 版本不会注册技能，只有
# `<cwd>/.claude/skills/<name>/SKILL.md` 才会进 init 的技能清单；frontmatter 里
# 本机不认的键会连技能一起丢掉，所以要就地重写 SKILL.md。
def stage_skills(workdir)
  dest = File.join(workdir, ".claude", "skills")
  staged = []
  Dir[File.join(REPO, "skills", "*", "SKILL.md")].sort.each do |skill|
    src = File.dirname(skill)
    out = File.join(dest, File.basename(src))
    FileUtils.mkdir_p(dest)
    FileUtils.cp_r(src, out)
    text = File.read(File.join(out, "SKILL.md"), encoding: "UTF-8")
    m = /\A---\s*\n(.*?)\n---\s*\n/m.match(text)
    if m
      keep = []
      skipping = false
      m[1].split("\n").each do |line|
        skipping = line.match?(/\A\S/) ? SKILL_FM_DROP.any? { |k| line.match?(/^#{k}:/) } : skipping
        keep << line unless skipping
      end
      rest = text[m.end(0)..] || ""
      File.write(File.join(out, "SKILL.md"), "---\n#{keep.join("\n")}\n---\n#{rest}")
    end
    staged << File.basename(src)
  end
  staged
end

# 模型在夹具副本里新增/修改的文本文件，并入内容评分（写了文件但没贴代码时兜底）。
def collect_artifacts(workdir)
  out = []
  Dir.glob(File.join(workdir, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
    next unless File.file?(path)
    rel = path.delete_prefix("#{workdir}/")
    next if SKIP_ARTIFACT_DIRS.include?(rel.split("/").first)
    begin
      cur = File.binread(path)
      orig = File.join(FIXTURE, rel)
      next if File.exist?(orig) && File.binread(orig) == cur
      next if cur.byteslice(0, 1024).to_s.include?("\x00".b)
      out << "--- #{rel} ---\n#{cur.byteslice(0, ARTIFACT_CAP).force_encoding("UTF-8").scrub}"
    rescue SystemCallError
      next
    end
  end
  out
end

# ---------------------------------------------------------------- 单轮运行

def capture(cmd, chdir:, env:, timeout:, out_path:, err_path:)
  pid = Process.spawn(env, *cmd, chdir: chdir, out: out_path, err: err_path, pgroup: true)
  timed_out = false
  begin
    Timeout.timeout(timeout) { Process.wait(pid) }
  rescue Timeout::Error
    timed_out = true
    [:TERM, :KILL].each do |sig|   # 负 pid = 整组；"-TERM" 这种写法 Ruby 直接报 EINVAL
      begin
        Process.kill(sig, -pid)
      rescue Errno::ESRCH
      end
      sleep 2
    end
    Process.wait(pid) rescue nil
  end
  [File.read(out_path), timed_out ? "timeout>#{timeout}s" : File.read(err_path)]
end

# 夹具在仓库里就是一个 git 工作树，副本也该是：不然 `git diff`、`git show` 全跑不了。
def init_git(workdir)
  env = { "GIT_AUTHOR_NAME" => "eval", "GIT_AUTHOR_EMAIL" => "eval@localhost",
          "GIT_COMMITTER_NAME" => "eval", "GIT_COMMITTER_EMAIL" => "eval@localhost" }
  ["git init -q", "git add -A", "git commit -qm fixture"].each do |c|
    system(env, *Shellwords.split(c), chdir: workdir, out: File::NULL, err: File::NULL)
  end
end

def run_one(kase, arm, args, known, meta, run_no = 1)
  workdir = Dir.mktmpdir("skilleval-#{kase['id']}-")
  tmp = Dir.mktmpdir("skilleval-io-")
  begin
    FileUtils.cp_r(File.join(FIXTURE, "."), workdir)
    stage_skills(workdir) unless arm == "noskills"
    init_git(workdir)

    cmd = ["claude", "-p", kase["prompt"],
           "--output-format", "stream-json", "--verbose",
           "--max-turns", args[:max_turns].to_s,
           "--max-budget-usd", args[:budget].to_s,
           "--tools", TOOLS,
           "--allowedTools", *BASH_ALLOW,
           "--permission-mode", "acceptEdits",
           "--strict-mcp-config",
           "--no-session-persistence"]
    # 技能只在夹具副本里的 .claude/skills（不再 --add-dir 真实技能目录，两臂对称）
    cmd += ["--disable-slash-commands"] if arm == "noskills"
    cmd += ["--model", args[:model]] unless args[:model].to_s.empty?

    env = { "CLAUDE_CONFIG_DIR" => args[:cc_config] }
    started = Time.now
    out = ""
    err = ""
    parsed = nil
    attempt = 0
    (RETRIES + 1).times do |i|
      attempt = i
      out, err = capture(cmd, chdir: workdir, env: env, timeout: args[:timeout],
                              out_path: File.join(tmp, "out"), err_path: File.join(tmp, "err"))
      parsed = parse_stream(out.split("\n"))
      break unless run_failed?(parsed) # 半截回答不是数据：必须见到 result 事件才算跑完
    end

    raw_dir = File.join(RESULTS, "raw", args[:stamp])
    FileUtils.mkdir_p(raw_dir)
    # 文件名必须带轮次：`--runs 3` 时同名会互相覆盖，原始 stream 一丢就没法重打分
    Zlib::GzipWriter.open(File.join(raw_dir, raw_name(arm, kase["id"], run_no))) { |gz| gz.write(out) }

    errored = run_failed?(parsed)
    artifacts = collect_artifacts(workdir) + parsed["writes"]
    answer = (parsed["answer"] + "\n" + artifacts.join("\n"))[0, ANSWER_CAP]

    { "case" => kase["id"], "arm" => arm, "run" => run_no, "bucket" => case_bucket(kase, meta),
      "seconds" => (Time.now - started).round(1),
      "cost" => parsed["cost"], "turns" => parsed["turns"],
      "denied" => parsed["denied"], "attempts" => attempt + 1, "ended" => parsed["ended"],
      "truncated" => ![nil, "success"].include?(parsed["ended"]),
      "artifacts" => artifacts.map { |a| a.lines.first.to_s.strip.delete_prefix("--- ").delete_suffix(" ---") },
      "error" => errored ? (err.strip[-200..].to_s.empty? ? "无 result 事件" : err.strip[-200..]) : nil,
      "score" => errored ? nil : score_case(kase, answer, parsed, known),
      "commands" => parsed["commands"].first(40).map { |c| c[0, 200] },
      "reads" => parsed["reads"].first(40),
      "init_skills" => parsed["init_skills"], "skill_denied" => parsed["skill_denied"],
      "answer_head" => parsed["answer"][0, 300] }
  ensure
    FileUtils.remove_entry(workdir, true)
    FileUtils.remove_entry(tmp, true)
  end
end

# 批次自检：数字发出去之前，先问一遍“这一批的测量本身成立吗”。
# 这里的每条都对应本会话真实踩过的坑，所以它是检查，不是提醒。
def self_check(results, planned:, cases:, known:, stamp:, raw_files: nil)
  raw_files ||= Dir[File.join(RESULTS, "raw", stamp, "*.jsonl.gz")].map { |f| File.basename(f) }
  expected = results.map { |r| raw_name(r["arm"], r["case"], r["run"]) }
  notes = []

  missing = expected - raw_files
  notes << [:hard, "#{missing.size} 轮没有原始 stream：#{missing.first(3).inspect}"] unless missing.empty?
  dupes = expected.tally.select { |_, n| n > 1 }.keys
  notes << [:hard, "同一(臂,用例,轮次)重复，文件名互相覆盖：#{dupes.first(3).inspect}"] unless dupes.empty?
  extra = raw_files - expected
  notes << [:warn, "raw 目录里另有 #{extra.size} 个不属于本轮的文件"] unless extra.empty?

  skipped = planned - results.size
  notes << [:warn, "本轮少了 #{skipped} 轮（熔断或中止）"] if skipped.positive?

  fails = results.count { |r| r["score"].nil? }
  if fails.positive?
    ratio = fails.to_f / results.size
    notes << [(ratio > 0.2 ? :hard : :warn), "#{fails}/#{results.size} 轮基础设施失败（>20% 就不是模型的问题）"]
  end

  # 技能注入自检：default 臂每轮都该看到全部仓库技能；noskills 臂一个都不该有
  results.each do |r|
    got = r["init_skills"]
    next if got.nil?
    if r["arm"] == "default"
      lack = known - got
      notes << [:hard, "#{r['case']}--r#{r['run']} init 里缺 #{lack.inspect}（注入失败或被 frontmatter 丢弃）"] unless lack.empty?
    elsif !got.empty?
      notes << [:warn, "#{r['case']}--r#{r['run']}：noskills 臂却看到 #{got.size} 个技能"]
    end
  end

  denied = results.sum { |r| r["skill_denied"].to_i }
  notes << [:warn, "#{denied} 次技能调用没拿到结果（不计触发，但说明框架在拒）"] if denied.positive?

  blank = cases.select { |c| c["forbid"] != "ALL" && Array(c["checks"]).empty? && Array(c["expect_tools"]).empty? }
  notes << [:warn, "只剩触发轴的用例：#{blank.map { |c| c['id'] }.inspect}"] unless blank.empty?
  notes
end

def self_check_text(notes)
  return "\n## 批次自检\n- ✅ 全绿（原始 stream 齐、技能集对、无异常失败）" if notes.empty?
  lines = ["\n## 批次自检"]
  notes.each { |level, text| lines << "- #{level == :hard ? '⛔' : '⚠'} #{text}" }
  lines.join("\n")
end

# ---------------------------------------------------------------- 汇总 / 报告

def mean(xs)
  xs = xs.compact
  xs.empty? ? nil : xs.sum.to_f / xs.size
end

def aggregate(results)
  ok = results.reject { |r| r["score"].nil? }
  default = ok.select { |r| r["arm"] == "default" }
  pos = default.select { |r| r["score"]["trigger_kind"] == "positive" }
  neg = default.select { |r| r["score"]["trigger_kind"] == "negative" }
  # 内容轴只看正例：反例的内容断言（“GIL 是什么”）谁都能答对，混进来会系统抬高通过率
  positive = ok.select { |r| r["score"]["trigger_kind"] == "positive" }
  content = positive.map { |r| r["score"]["content"] }
  behavior = positive.map { |r| r["score"]["behavior"] }
  fired_count = Hash.new(0)
  ok.each { |r| r["score"]["fired"].each { |s| fired_count[s] += 1 } }

  { "n" => ok.size, "errors" => results.size - ok.size,
    "trigger_recall" => mean(pos.map { |r| r["score"]["trigger"] ? 1 : 0 }),
    "false_trigger_rate" => mean(neg.map { |r| r["score"]["trigger"] ? 0 : 1 }),
    "content" => mean(content),
    "behavior" => mean(behavior),
    "composite" => mean(pos.select { |r| r["score"]["content"] }
                            .map { |r| 0.5 * (r["score"]["trigger"] ? 1 : 0) + 0.5 * r["score"]["content"] }),
    "cost" => results.sum { |r| r["cost"].to_f },
    "fired_count" => fired_count.sort_by { |k, v| [-v, k] }.to_h }
end

def pct(x)
  x.nil? ? "-" : format("%.0f%%", x * 100)
end

def report(results, arms)
  lines = []
  arms.each do |arm|
    rs = results.select { |r| r["arm"] == arm }
    agg = aggregate(rs)
    lines << ""
    lines << "## 臂：#{arm}（#{agg['n']} 个有效，#{agg['errors']} 个基础设施失败，$#{format('%.2f', agg['cost'])}）"
    if arm == "default"
      bucket = ->(b) { rs.select { |r| r["score"] && r["score"]["trigger_kind"] == "positive" && r["bucket"] == b } }
      auto = bucket.call("auto")
      human = bucket.call("human")
      lines << "- 触发召回（正例）：#{pct(agg['trigger_recall'])}（可自动调用 #{auto.size} 例 #{pct(mean(auto.map { |r| r['score']['trigger'] ? 1 : 0 }))}；仅人工调用 #{human.size} 例 #{pct(mean(human.map { |r| r['score']['trigger'] ? 1 : 0 }))}）"
      lines << "- 误触发率（反例，越低越好）：#{pct(agg['false_trigger_rate'])}"
      lines << "- 各技能被触发次数：#{agg['fired_count'].inspect}"
    end
    lines << "- 内容通过率（正例）：#{pct(agg['content'])}"
    lines << "- 行为轴（要求真去跑的门）：#{pct(agg['behavior'])}"
    lines << "- 综合分（触发 50% + 内容 50%）：#{pct(agg['composite'])}" if arm == "default"
    trunc = rs.select { |r| r["truncated"] }.map { |r| r["case"] }
    lines << "- ⚠ 被 max-turns/预算截断（内容分不可信）：#{trunc.inspect}" unless trunc.empty?

    # 多轮：先按用例看稳定性，再看单轮明细（单轮方差是这里最容易骗人的地方）
    groups = rs.select { |r| r["score"] }.group_by { |r| r["case"] }
    if groups.values.any? { |g| g.size > 1 }
      lines << ""
      lines << "### 按用例汇总（每例 #{groups.values.map(&:size).max} 轮）"
      lines << ""
      lines << "| 用例 | 触发 | 内容 | 行为 | 各轮触发 |"
      lines << "|---|---|---|---|---|"
      groups.each do |cid, g|
        trig = g.select { |r| r["score"]["trigger"] }.size
        chk = g.flat_map { |r| r["score"]["checks"] }
        beh = g.flat_map { |r| r["score"]["behaviors"] }
        marks = g.map { |r| r["score"]["trigger"] ? "✓" : "✗" }.join
        lines << "| #{cid} | #{trig}/#{g.size} | #{chk.count { |c| c['pass'] }}/#{chk.size} | " \
                 "#{beh.empty? ? '-' : "#{beh.count { |b| b['pass'] }}/#{beh.size}"} | #{arm == 'noskills' ? '-' : marks} |"
      end
    end

    lines << ""
    lines << "| 用例 | 触发 | 内容 | 行为 | 触发了 | 秒 | $ |"
    lines << "|---|---|---|---|---|---|---|"
    rs.each do |r|
      unless r["score"]
        lines << "| #{r['case']} | 失败 | - | - | #{r['error']} | #{r['seconds']} | #{format('%.2f', r['cost'])} |"
        next
      end
      s = r["score"]
      ok_checks = s["checks"].count { |c| c["pass"] }
      beh = s["behaviors"]
      beh_cell = beh.empty? ? "-" : "#{beh.count { |b| b['pass'] }}/#{beh.size}"
      content_cell = s["checks"].empty? ? "未测" : "#{ok_checks}/#{s['checks'].size}"
      trig = arm == "noskills" ? "-" : (s["trigger"] ? "✓" : "✗")
      denied = r["denied"].empty? ? "" : " /#{r['denied'].size}拒"
      fired = s["fired"].empty? ? "-" : s["fired"].join(",")
      lines << "| #{r['case']} | #{trig} | #{content_cell} | #{beh_cell} | #{fired} | #{r['seconds']}#{denied} | #{format('%.2f', r['cost'])} |"
    end
  end

  if arms.include?("default") && arms.include?("noskills")
    d = aggregate(results.select { |r| r["arm"] == "default" })["content"]
    b = aggregate(results.select { |r| r["arm"] == "noskills" })["content"]
    lines << ""
    lines << "## 技能增益"
    lines << "内容通过率（正例）default #{pct(d)} − noskills #{pct(b)} = #{format('%+.0f%%', (d.to_f - b.to_f) * 100)}"
  end
  lines.join("\n")
end

# ---------------------------------------------------------------- 入口

def parse_args(argv)
  args = { arms: "default", only: "", runs: 1, jobs: 3, max_turns: 40, budget: 2.0,
           timeout: 900, model: "", bucket: "", rescore: "" }
  OptionParser.new do |ap|
    ap.on("--arms ARMS", "逗号分隔，如 default,noskills") { |v| args[:arms] = v }
    ap.on("--only IDS", "只跑这些用例（逗号分隔）") { |v| args[:only] = v }
    ap.on("--bucket B", "按桶筛：auto,human,negative") { |v| args[:bucket] = v }
    ap.on("--runs N", Integer) { |v| args[:runs] = v }
    ap.on("--jobs N", Integer) { |v| args[:jobs] = v }
    ap.on("--max-turns N", Integer) { |v| args[:max_turns] = v }
    ap.on("--budget USD", Float) { |v| args[:budget] = v }
    ap.on("--timeout SEC", Integer) { |v| args[:timeout] = v }
    ap.on("--model ID") { |v| args[:model] = v }
    ap.on("--rescore SRC", "不跑模型：用当前 cases.json 重打结果（results/raw/<STAMP> 或 results/<STAMP>.json）") { |v| args[:rescore] = v }
  end.parse(argv)
  args
end

# 原始 stream 的文件名（归一成一个地方，重打分靠它拆分）
def raw_parts(basename)
  stem = basename.sub(/\.jsonl\.gz\z/, "")
  parts = stem.split("--")
  run_no = parts.last.to_s.match?(/\Ar\d+\z/) ? parts.pop.delete_prefix("r").to_i : 1
  [parts[0], parts[1], run_no]
end

# 改断言后不必重跑：用当前 cases.json 重新打分。
# 两种源都行：results/raw/<stamp>（原始事件流）或 results/<stamp>.json（已跑但被删了断言的旧结果）。
def rescore(source, model)
  cases = JSON.parse(File.read(CASES)).to_h { |c| [c["id"], c] }
  known = known_skills
  meta = skill_meta
  out =
    if source.end_with?(".json")
      stale = JSON.parse(File.read(source))["results"]
      stale.map do |r|
        kept = r["score"] && r["score"]["checks"].select do |c|
          Array(cases[r["case"]]["checks"]).any? { |k| k["name"] == c["name"] }
        end
        score = if r["score"].nil?
                  nil
                else
                  passed = kept.count { |c| c["pass"] }
                  # 老结果里没有 commands（那时还没记）：别硬算成 0，沿用存档的判定
                  beh = if r.key?("commands")
                          behaviors_for(cases[r["case"]], r["commands"],
                                        Array(r["artifacts"]).map { |a| "--- #{a} ---" } + Array(r["reads"]))
                        else
                          (r["score"]["behaviors"] || [])
                        end
                  r["score"].merge("checks" => kept, "behaviors" => beh,
                                   "behavior" => beh.empty? ? nil : beh.count { |b| b["pass"] }.to_f / beh.size,
                                   "content" => kept.empty? ? nil : passed.to_f / kept.size)
                end
        r.merge("score" => score)
      end
    else
      dir = File.join(RESULTS, "raw", source)
      abort "没有 #{dir}" unless Dir.exist?(dir)
      Dir[File.join(dir, "*.jsonl.gz")].sort.map do |path|
        arm, cid, run_no = raw_parts(File.basename(path))
        parsed = Zlib::GzipReader.open(path) { |gz| parse_stream(gz.read.split("\n")) }
        answer = (parsed["answer"] + "\n" + parsed["writes"].join("\n"))[0, ANSWER_CAP]
        errored = run_failed?(parsed)
        { "case" => cid, "arm" => arm, "run" => run_no, "bucket" => case_bucket(cases[cid], meta),
          "seconds" => 0, "cost" => parsed["cost"], "turns" => parsed["turns"],
          "denied" => parsed["denied"], "attempts" => 1, "ended" => parsed["ended"],
          "truncated" => ![nil, "success"].include?(parsed["ended"]),
          "artifacts" => parsed["writes"].map { |a| a.lines.first.to_s.strip.delete_prefix("--- ").delete_suffix(" ---") },
          "error" => errored ? "无 result 事件" : nil,
          "commands" => parsed["commands"].first(40).map { |c| c[0, 200] },
          "reads" => parsed["reads"].first(40),
          "score" => errored ? nil : score_case(cases[cid], answer, parsed, known),
          "answer_head" => parsed["answer"][0, 300] }
      end
    end

  arms = out.map { |r| r["arm"] }.uniq.sort
  text = +"# 重新打分 #{Time.now.strftime('%Y-%m-%d %H:%M')}（源 #{File.basename(source)}，模型 #{model}，用例集 = 当前 cases.json）\n"
  text << "只保留当前 cases.json 里还在的断言"
  text << report(out, arms)
  File.write(File.join(RESULTS, "#{File.basename(source, '.json')}.rescore.md"), text)
  File.write(File.join(RESULTS, "#{File.basename(source, '.json')}.rescore.json"),
             JSON.pretty_generate({ "rescore_of" => source, "results" => out }))
  puts text
end

def workers_hint(args, n)
  [[args[:jobs], n].min, 1].max
end

def main(argv)
  args = parse_args(argv)
  return rescore(args[:rescore], args[:model]) unless args[:rescore].to_s.empty?

  known = known_skills
  meta = skill_meta
  cases = JSON.parse(File.read(CASES))

  cases = cases.select { |c| args[:only].split(",").include?(c["id"]) } unless args[:only].empty?
  unless args[:bucket].empty?
    wanted = args[:bucket].split(",")
    cases = cases.select do |c|
      b = case_bucket(c, meta) || "negative"
      wanted.include?(b)
    end
  end
  arms = args[:arms].split(",")
  model = args[:model].empty? ? "env-default" : args[:model]
  args[:stamp] = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{model.gsub(/[^A-Za-z0-9.]+/, '-')}"
  args[:cc_config] = make_cc_config

  jobs = []
  arms.each do |a|
    cases.each do |c|
      (1..args[:runs]).each { |n| jobs << [c, a, n] }
    end
  end

  results = Array.new(jobs.size)
  queue = Queue.new
  jobs.each_with_index { |job, i| queue << [i, job] }
  errors = []
  health = BatchHealth.new
  warn "#{jobs.size} 轮开跑（模型 #{model}，臂 #{arms.join('/')}，#{workers_hint(args, jobs.size)} 并发）"
  begin
    workers = [[args[:jobs], jobs.size].min, 1].max
    workers.times.map do
      Thread.new do
        loop do
          break if health.aborted?
          i, (kase, arm, run_no) = queue.pop(true)
          failed = nil
          2.times do |attempt|
            begin
              results[i] = run_one(kase, arm, args, known, meta, run_no)
              failed = nil
              break
            rescue StandardError => e
              failed = e
              warn "重试 #{kase['id']}/#{arm}：#{e.class}: #{e.message}\n  #{Array(e.backtrace).first(3).join("\n  ")}"
              sleep 5
            end
          end
          unless failed.nil?
            errors << failed
          end
          ok = failed.nil? && !results[i]["score"].nil?
          health.record(ok: ok, signature: results[i]["error"].to_s[0, 70])
          snap = health.snapshot
          warn format("[%d/%d] %s--%s--r%d %s %gs $%.2f%s", snap[:done], jobs.size, arm, kase["id"], run_no,
                      results[i]["score"].nil? ? "失败" : (results[i]["score"]["trigger"] ? "✓" : "✗"),
                      results[i]["seconds"], results[i]["cost"], snap[:fails].positive? ? " 失败#{snap[:fails]}" : "")
          next if failed.nil?
          results[i] = { "case" => kase["id"], "arm" => arm, "bucket" => case_bucket(kase, meta),
                         "seconds" => 0, "cost" => 0.0, "turns" => 0, "denied" => [],
                         "attempts" => 0, "ended" => nil, "truncated" => true, "artifacts" => [],
                         "error" => "#{failed.class}: #{failed.message} @ #{failed.backtrace&.first}",
                         "score" => nil, "answer_head" => "" }
          break if health.aborted?
        end
      rescue ThreadError
        nil
      end
    end.each(&:join)
  ensure
    FileUtils.remove_entry(args[:cc_config], true)
  end
  errors.each { |e| warn "worker error: #{e.class}: #{e.message}" }
  aborted = health.snapshot[:abort]
  warn "已熔断：#{aborted}（剩下 #{results.count(&:nil?)} 轮没跑）" if aborted
  results = results.compact

  head = IO.popen(["git", "rev-parse", "--short", "HEAD"], chdir: REPO, &:read).strip
  ver = claude_version
  text = +"# 技能评估 #{Time.now.strftime('%Y-%m-%d %H:%M')}（模型 #{model}，fork HEAD #{head}，claude #{ver}，runs=#{args[:runs]}）\n"
  text << "隔离：空 CLAUDE_CONFIG_DIR = 无个人技能/插件/hook；技能以 .claude/skills 注入夹具"
  text << "（剥 #{SKILL_FM_DROP.join('、')}）；触发只算加载成功的技能"
  notes = self_check(results, planned: jobs.size, cases: cases, known: known, stamp: args[:stamp])
  text << report(results, arms)
  text << self_check_text(notes)

  FileUtils.mkdir_p(RESULTS)
  File.write(File.join(RESULTS, "#{args[:stamp]}.json"),
             JSON.pretty_generate({ "head" => head, "model" => model, "claude" => ver,
                                    "isolated" => true, "results" => results }))
  File.write(File.join(RESULTS, "#{args[:stamp]}.md"), text)
  puts text
  hard = notes.any? { |level, _| level == :hard }
  exit(hard ? 2 : (results.any? { |r| r["score"].nil? } ? 1 : 0))
end

main(ARGV) if $PROGRAM_NAME == __FILE__
