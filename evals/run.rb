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

# ---------------------------------------------------------------- 事件流解析

# 从 stream-json 事件里提取：**加载成功**的技能、回答文本、成本、轮数、被拒的工具。
#
# 失败的调用不算加载：被权限拒的 Skill 调用、报错的 Read 都拿不到技能正文，
# 计成 fired 会白送一分（历史上 mac 轮没放行 Skill，系统性高估就在这里）。
def parse_stream(lines)
  pending = {}   # tool_use_id -> skill 名
  loaded = []
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
          pending[block["id"].to_s] = name if name
        end
      end
    when "user"
      Array(ev.dig("message", "content")).each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_result"
        name = pending.delete(block["tool_use_id"].to_s)
        loaded << name if name && !block["is_error"]
      end
    when "system"
      next unless ev["subtype"] == "permission_denied"
      denied << (ev["tool_name"] || ev.dig("tool", "name") || "?")
    when "result"
      cost = ev["total_cost_usd"].to_f
      turns = ev["num_turns"].to_i
      result_text = ev["result"]
      ended = ev["subtype"]
    end
  end

  answer = texts.join("\n")
  answer += "\n#{result_text}" if result_text && !answer.include?(result_text)
  { "fired" => loaded.uniq.sort, "answer" => answer, "cost" => cost, "turns" => turns,
    "denied" => denied, "ended" => ended }
end

# 没有 result 事件（超时/崩溃）或没有回答 = 基础设施失败，不是数据。
def run_failed?(parsed)
  parsed["ended"].nil? || parsed["answer"].to_s.strip.empty?
end

# ---------------------------------------------------------------- 评分

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

  passed = checks.count { |c| c["pass"] }
  { "trigger_kind" => trigger_kind, "trigger" => trigger, "fired" => fired.sort,
    "checks" => checks, "content" => checks.empty? ? 1.0 : passed.to_f / checks.size }
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
    ["-TERM", "-KILL"].each do |sig|
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

def run_one(kase, arm, args, known, meta)
  workdir = Dir.mktmpdir("skilleval-#{kase['id']}-")
  tmp = Dir.mktmpdir("skilleval-io-")
  begin
    FileUtils.cp_r(File.join(FIXTURE, "."), workdir)
    stage_skills(workdir) unless arm == "noskills"

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
    Zlib::GzipWriter.open(File.join(raw_dir, "#{arm}--#{kase['id']}.jsonl.gz")) { |gz| gz.write(out) }

    errored = run_failed?(parsed)
    artifacts = collect_artifacts(workdir)
    answer = (parsed["answer"] + "\n" + artifacts.join("\n"))[0, ANSWER_CAP]

    { "case" => kase["id"], "arm" => arm, "bucket" => case_bucket(kase, meta),
      "seconds" => (Time.now - started).round(1),
      "cost" => parsed["cost"], "turns" => parsed["turns"],
      "denied" => parsed["denied"], "attempts" => attempt + 1, "ended" => parsed["ended"],
      "truncated" => ![nil, "success"].include?(parsed["ended"]),
      "artifacts" => artifacts.map { |a| a.lines.first.to_s.strip.delete_prefix("--- ").delete_suffix(" ---") },
      "error" => errored ? (err.strip[-200..].to_s.empty? ? "无 result 事件" : err.strip[-200..]) : nil,
      "score" => errored ? nil : score_case(kase, answer, parsed, known),
      "answer_head" => parsed["answer"][0, 300] }
  ensure
    FileUtils.remove_entry(workdir, true)
    FileUtils.remove_entry(tmp, true)
  end
end

# ---------------------------------------------------------------- 汇总 / 报告

def mean(xs)
  xs.empty? ? nil : xs.sum.to_f / xs.size
end

def aggregate(results)
  ok = results.reject { |r| r["score"].nil? }
  default = ok.select { |r| r["arm"] == "default" }
  pos = default.select { |r| r["score"]["trigger_kind"] == "positive" }
  neg = default.select { |r| r["score"]["trigger_kind"] == "negative" }
  fired_count = Hash.new(0)
  ok.each { |r| r["score"]["fired"].each { |s| fired_count[s] += 1 } }

  { "n" => ok.size, "errors" => results.size - ok.size,
    "trigger_recall" => mean(pos.map { |r| r["score"]["trigger"] ? 1 : 0 }),
    "false_trigger_rate" => mean(neg.map { |r| r["score"]["trigger"] ? 0 : 1 }),
    "content" => mean(ok.map { |r| r["score"]["content"] }),
    "composite" => mean(default.map { |r| 0.5 * (r["score"]["trigger"] ? 1 : 0) + 0.5 * r["score"]["content"] }),
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
    lines << "- 内容通过率：#{pct(agg['content'])}"
    lines << "- 综合分（触发 50% + 内容 50%）：#{pct(agg['composite'])}" if arm == "default"
    trunc = rs.select { |r| r["truncated"] }.map { |r| r["case"] }
    lines << "- ⚠ 被 max-turns/预算截断（内容分不可信）：#{trunc.inspect}" unless trunc.empty?

    lines << ""
    lines << "| 用例 | 触发 | 内容 | 触发了 | 秒 | $ |"
    lines << "|---|---|---|---|---|---|"
    rs.each do |r|
      unless r["score"]
        lines << "| #{r['case']} | 失败 | - | #{r['error']} | #{r['seconds']} | #{format('%.2f', r['cost'])} |"
        next
      end
      s = r["score"]
      ok_checks = s["checks"].count { |c| c["pass"] }
      trig = arm == "noskills" ? "-" : (s["trigger"] ? "✓" : "✗")
      denied = r["denied"].empty? ? "" : " /#{r['denied'].size}拒"
      fired = s["fired"].empty? ? "-" : s["fired"].join(",")
      lines << "| #{r['case']} | #{trig} | #{ok_checks}/#{s['checks'].size} | #{fired} | #{r['seconds']}#{denied} | #{format('%.2f', r['cost'])} |"
    end
  end

  if arms.include?("default") && arms.include?("noskills")
    d = aggregate(results.select { |r| r["arm"] == "default" })["content"]
    b = aggregate(results.select { |r| r["arm"] == "noskills" })["content"]
    lines << ""
    lines << "## 技能增益"
    lines << "内容通过率 default #{pct(d)} − noskills #{pct(b)} = #{format('%+.0f%%', (d.to_f - b.to_f) * 100)}"
  end
  lines.join("\n")
end

# ---------------------------------------------------------------- 入口

def parse_args(argv)
  args = { arms: "default", only: "", runs: 1, jobs: 3, max_turns: 30, budget: 1.5,
           timeout: 420, model: "", bucket: "" }
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
  end.parse(argv)
  args
end

def main(argv)
  args = parse_args(argv)
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
  arms.each { |a| cases.each { |c| args[:runs].times { jobs << [c, a] } } }

  results = Array.new(jobs.size)
  queue = Queue.new
  jobs.each_with_index { |job, i| queue << [i, job] }
  errors = []
  begin
    workers = [[args[:jobs], jobs.size].min, 1].max
    workers.times.map do
      Thread.new do
        loop do
          i, (kase, arm) = queue.pop(true)
          begin
            results[i] = run_one(kase, arm, args, known, meta)
          rescue StandardError => e
            errors << e
            results[i] = { "case" => kase["id"], "arm" => arm, "bucket" => case_bucket(kase, meta),
                           "seconds" => 0, "cost" => 0.0, "turns" => 0, "denied" => [],
                           "attempts" => 0, "ended" => nil, "truncated" => true, "artifacts" => [],
                           "error" => "#{e.class}: #{e.message}", "score" => nil, "answer_head" => "" }
          end
        end
      rescue ThreadError
        nil
      end
    end.each(&:join)
  ensure
    FileUtils.remove_entry(args[:cc_config], true)
  end
  errors.each { |e| warn "worker error: #{e.class}: #{e.message}" }

  head = IO.popen(["git", "rev-parse", "--short", "HEAD"], chdir: REPO, &:read).strip
  ver = claude_version
  text = +"# 技能评估 #{Time.now.strftime('%Y-%m-%d %H:%M')}（模型 #{model}，fork HEAD #{head}，claude #{ver}，runs=#{args[:runs]}）\n"
  text << "隔离：空 CLAUDE_CONFIG_DIR = 无个人技能/插件/hook；技能以 .claude/skills 注入夹具"
  text << "（剥 #{SKILL_FM_DROP.join('、')}）；触发只算加载成功的技能"
  text << report(results, arms)

  FileUtils.mkdir_p(RESULTS)
  File.write(File.join(RESULTS, "#{args[:stamp]}.json"),
             JSON.pretty_generate({ "head" => head, "model" => model, "claude" => ver,
                                    "isolated" => true, "results" => results }))
  File.write(File.join(RESULTS, "#{args[:stamp]}.md"), text)
  puts text
  exit(results.any? { |r| r["score"].nil? } ? 1 : 0)
end

main(ARGV) if $PROGRAM_NAME == __FILE__
