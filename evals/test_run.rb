# frozen_string_literal: true
#
# 评分逻辑与用例集自检（不调用模型）。守卫要双向验：每条断言都配负控。
#
#   ruby evals/test_run.rb

require "minitest/autorun"
require "tmpdir"

require_relative "run"

TEST_CASES = JSON.parse(File.read(File.join(__dir__, "cases.json")))
TEST_KNOWN = known_skills
TEST_META = skill_meta
CASE_MAP = TEST_CASES.to_h { |c| [c["id"], c] }

def stream(*events) = events.map { |e| JSON.generate(e) }
def assistant(*blocks) = { "type" => "assistant", "message" => { "content" => blocks } }
def skill_call(name, tid = "t1")
  { "type" => "tool_use", "id" => tid, "name" => "Skill", "input" => { "skill" => name } }
end
def read_file(path, tid = "t1")
  { "type" => "tool_use", "id" => tid, "name" => "Read", "input" => { "file_path" => path } }
end
def tool_result(tid = "t1", is_error: false)
  { "type" => "user",
    "message" => { "content" => [{ "type" => "tool_result", "tool_use_id" => tid,
                                   "content" => "...", "is_error" => is_error }] } }
end
def text(t) = { "type" => "text", "text" => t }

class CaseFileTest < Minitest::Test
  def test_scan_set_not_empty
    # 扫描集为空会让下面所有断言静默变绿
    assert_operator TEST_KNOWN.size, :>=, 10
    assert_equal TEST_KNOWN.size, TEST_META.size
  end

  def test_ids_unique
    ids = TEST_CASES.map { |c| c["id"] }
    assert_equal ids.size, ids.uniq.size
  end

  def test_expect_any_names_exist
    TEST_CASES.each do |c|
      Array(c["expect_any"]).each do |name|
        assert_includes TEST_KNOWN, name, "#{c['id']}: 未知技能 #{name}"
      end
    end
  end

  def test_every_case_is_positive_or_negative
    TEST_CASES.each do |c|
      positive = !Array(c["expect_any"]).empty?
      negative = c["forbid"] == "ALL"
      assert positive ^ negative, c["id"]
    end
  end

  def test_regexes_compile
    TEST_CASES.each do |c|
      Array(c["checks"]).each do |chk|
        refute_empty Array(chk["any"]), "#{c['id']}/#{chk['name']}"
        (Array(chk["any"]) + Array(chk["avoid"])).each do |p|
          assert_silent { Regexp.new(p) }
        end
      end
    end
  end

  def test_axes_are_not_silently_empty
    # 预筛会剪掉没有判别力的断言；剪空即只剩触发轴（报告里显示“未测”）。
    # 这里只守住“量表整体不为空”，否则跑完一轮什么都没测也看不出来。
    refute_empty TEST_CASES.flat_map { |c| Array(c["checks"]) }
    refute_empty TEST_CASES.flat_map { |c| Array(c["expect_tools"]) }
  end

  def test_expect_tools_regexes_compile
    TEST_CASES.each do |c|
      Array(c["expect_tools"]).each do |b|
        refute_empty Array(b["cmd"]), "#{c['id']}/#{b['name']}"
        Array(b["cmd"]).each { |p| assert_silent { Regexp.new(p) } }
      end
    end
  end

  def test_has_both_positive_and_negative_cases
    assert TEST_CASES.any? { |c| c["forbid"] }
    assert TEST_CASES.any? { |c| c["expect_any"] }
  end

  def test_fixture_exists_and_triggers_paths
    assert File.exist?(File.join(FIXTURE, "app/helpers/posts_helper.rb"))
    assert File.exist?(File.join(FIXTURE, "Gemfile"))
  end

  def test_matching_is_case_insensitive
    kase = { "id" => "x", "prompt" => "", "expect_any" => ["rails-jobs"],
             "checks" => [{ "name" => "a", "any" => ["idempot"] }] }
    parsed = { "fired" => ["rails-jobs"], "answer" => "IDEMPOTENT", "cost" => 0.0,
               "turns" => 0, "denied" => [], "ended" => "success" }
    assert_equal 1.0, score_case(kase, "IDEMPOTENT", parsed, TEST_KNOWN)["content"]
  end
end

class SkillMetaTest < Minitest::Test
  def test_negative_control_human_only
    refute TEST_META["dhh"]
    refute TEST_META["rails-jobs"]
  end

  def test_positive_control_auto
    assert TEST_META["rails-conventions"]
    assert TEST_META["rails-best-practices-core"]
  end

  def test_both_buckets_present_in_cases
    buckets = TEST_CASES.map { |c| case_bucket(c, TEST_META) }.compact.uniq.sort
    assert_equal %w[auto human], buckets
  end
end

class BucketTest < Minitest::Test
  def test_auto_and_human_and_none
    assert_equal "auto", case_bucket(CASE_MAP["helper-naming"], TEST_META)
    assert_equal "human", case_bucket(CASE_MAP["jobs-idempotent"], TEST_META)
    assert_nil case_bucket(CASE_MAP["neg-python-gil"], TEST_META)
  end
end

class RunFailedTest < Minitest::Test
  def test_no_result_event_is_failure
    assert run_failed?({ "ended" => nil, "answer" => "半截回答" })
  end

  def test_empty_answer_is_failure
    assert run_failed?({ "ended" => "success", "answer" => "  " })
  end

  def test_success_with_answer
    refute run_failed?({ "ended" => "success", "answer" => "答案" })
  end

  def test_max_turns_with_answer_is_data
    refute run_failed?({ "ended" => "error_max_turns", "answer" => "答案" })
  end

  def test_provider_error_is_failure_not_data
    # 负控：网关错误走 success 通道回来时，不能计成一次"答得很差"
    gateway = { "ended" => "success", "result_error" => true, "api_error_status" => 401,
                "answer" => "Failed to authenticate. API Error: 401 The API Key has been disabled." }
    assert run_failed?(gateway)
    assert run_failed?({ "ended" => "success", "answer" => "Failed to authenticate. API Error: 401" })
    assert run_failed?({ "ended" => "success", "answer" => "API Error: 429 限额" })
  end

  def test_normal_answer_mentioning_auth_is_data
    # 正控：答案里正常讨论鉴权不算失败
    refute run_failed?({ "ended" => "success", "answer" => "签名用 secure_compare；未通过就 head :forbidden" })
  end
end

class ParseTest < Minitest::Test
  def test_skill_call_and_namespacing
    p = parse_stream(stream(assistant(skill_call("plugin:rails-jobs"), text("ok")), tool_result))
    assert_equal ["rails-jobs"], p["fired"]
  end

  def test_skill_md_read_counts
    read = read_file("/x/skills/rails-testing/SKILL.md")
    assert_equal ["rails-testing"], parse_stream(stream(assistant(read), tool_result))["fired"]
  end

  def test_ordinary_read_does_not_count
    read = read_file("/x/app/models/post.rb")
    assert_empty parse_stream(stream(assistant(read), tool_result))["fired"]
  end

  def test_failed_skill_call_does_not_count
    # 负控：被拒的 Skill 调用（disable-model-invocation / 权限）拿不到正文，不能算加载
    p = parse_stream(stream(assistant(skill_call("rails-jobs")), tool_result(is_error: true)))
    assert_empty p["fired"]
  end

  def test_failed_read_does_not_count
    read = read_file("/x/skills/rails-testing/SKILL.md")
    p = parse_stream(stream(assistant(read), tool_result(is_error: true)))
    assert_empty p["fired"]
  end

  def test_call_without_result_does_not_count
    # 负控：事件流被截断时看不到结果，宁可漏计也不能白送
    p = parse_stream(stream(assistant(skill_call("rails-jobs"))))
    assert_empty p["fired"]
  end

  def test_garbage_lines_ignored
    assert_empty parse_stream(["not json", "{bad"])["fired"]
  end

  def test_denied_and_ended_recorded
    denied = { "type" => "system", "subtype" => "permission_denied", "tool_name" => "Bash" }
    p = parse_stream(stream(denied, { "type" => "result", "subtype" => "success", "result" => "x" }))
    assert_equal ["Bash"], p["denied"]
    assert_equal "success", p["ended"]
  end

  def test_cost_and_result
    p = parse_stream(stream({ "type" => "result", "total_cost_usd" => 0.2, "num_turns" => 3, "result" => "答案" }))
    assert_equal [0.2, 3, "答案"], [p["cost"], p["turns"], p["answer"].strip]
  end
end

class ArtifactTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("artifact-test-")
    FileUtils.cp_r(File.join(FIXTURE, "."), @dir)
  end

  def teardown
    FileUtils.remove_entry(@dir, true)
  end

  def test_new_and_modified_collected_untouched_skipped
    File.write(File.join(@dir, "app/javascript/controllers/clipboard_controller.js"), "export default class {}")
    File.write(File.join(@dir, "app/models/post.rb"), "# modified\n")
    names = collect_artifacts(@dir).map { |a| a.lines.first.to_s.strip }
    assert_includes names, "--- app/javascript/controllers/clipboard_controller.js ---"
    assert_includes names, "--- app/models/post.rb ---"
    refute_includes names, "--- app/helpers/posts_helper.rb ---"
  end

  def test_binary_skipped
    File.binwrite(File.join(@dir, "db/test.sqlite3"), "\x00\x01binary".b)
    assert_empty collect_artifacts(@dir)
  end
end

class ScoreTest < Minitest::Test
  POS = { "id" => "t", "prompt" => "", "expect_any" => ["rails-jobs"],
          "checks" => [{ "name" => "a", "any" => ["幂等"] }, { "name" => "b", "any" => ["notified_at"] }] }.freeze
  NEG = { "id" => "n", "prompt" => "", "forbid" => "ALL",
          "checks" => [{ "name" => "a", "any" => ["GIL"] }] }.freeze

  def parsed(fired)
    { "fired" => fired, "answer" => "", "cost" => 0.0, "turns" => 0, "denied" => [], "ended" => "success" }
  end

  def test_positive_hit
    s = score_case(POS, "做成幂等，用 notified_at", parsed(["rails-jobs"]), TEST_KNOWN)
    assert s["trigger"]
    assert_equal 1.0, s["content"]
  end

  def test_positive_miss_trigger
    s = score_case(POS, "幂等", parsed(["rails-testing"]), TEST_KNOWN)
    refute s["trigger"]
    assert_equal 0.5, s["content"]
  end

  def test_positive_no_fire
    refute score_case(POS, "", parsed([]), TEST_KNOWN)["trigger"]
  end

  def test_negative_clean
    assert score_case(NEG, "GIL 是锁", parsed([]), TEST_KNOWN)["trigger"]
  end

  def test_negative_false_trigger
    refute score_case(NEG, "GIL", parsed(["rails-jobs"]), TEST_KNOWN)["trigger"]
  end

  def test_negative_ignores_non_rails_skills
    assert score_case(NEG, "GIL", parsed(["find-skills"]), TEST_KNOWN)["trigger"]
  end

  def test_avoid_pattern_blocks_hit
    kase = { "id" => "x", "prompt" => "", "expect_any" => ["rails-jobs"],
             "checks" => [{ "name" => "a", "any" => ["scope"], "avoid" => ["select"] }] }
    good = score_case(kase, "用 scope :published", parsed(["rails-jobs"]), TEST_KNOWN)["content"]
    bad = score_case(kase, "Post.all.select { }", parsed(["rails-jobs"]), TEST_KNOWN)["content"]
    assert_equal [1.0, 0.0], [good, bad]
  end

  def def_result(case_id, arm, trigger, content, cost = 0.1)
    { "case" => case_id, "arm" => arm, "cost" => cost, "bucket" => "auto", "truncated" => false,
      "score" => { "trigger_kind" => "positive", "trigger" => trigger, "fired" => [], "checks" => [],
                   "content" => content } }
  end

  def test_aggregate_excludes_infra_errors
    good = def_result("a", "default", true, 1.0)
    bad = { "case" => "b", "arm" => "default", "cost" => 0.1, "score" => nil }
    agg = aggregate([good, bad])
    assert_equal [1, 1, 1.0], [agg["n"], agg["errors"], agg["trigger_recall"]]
  end

  def test_aggregate_trigger_stats_only_from_default_arm
    d = def_result("a", "default", true, 1.0)
    n = def_result("a", "noskills", false, 0.5)
    agg = aggregate([d, n])
    assert_equal 1.0, agg["trigger_recall"]
    assert_equal 0.75, agg["content"]
    assert_equal 1.0, agg["composite"]
  end

  def test_aggregate_content_ignores_negative_cases
    # 反例的内容断言谁都能答对，混进内容通过率会系统抬高技能增益
    pos = def_result("a", "default", true, 0.5)
    neg = def_result("n", "default", true, 1.0).merge(
      "score" => { "trigger_kind" => "negative", "trigger" => true, "fired" => [],
                   "checks" => [], "content" => 1.0 }
    )
    assert_equal 0.5, aggregate([pos, neg])["content"]
  end

  def test_aggregate_empty
    agg = aggregate([])
    assert_equal 0, agg["n"]
    assert_nil agg["trigger_recall"] # nil，不是静默的 0
  end
end

class RawNameTest < Minitest::Test
  def test_parts_with_and_without_run_index
    assert_equal ["default", "helper-naming", 1], raw_parts("default--helper-naming.jsonl.gz")
    assert_equal ["noskills", "helper-naming", 3], raw_parts("noskills--helper-naming--r3.jsonl.gz")
  end
end
