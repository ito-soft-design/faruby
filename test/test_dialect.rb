# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/dialect"
require_relative "../tools/kvs_generator"

# 生成コードの綴り方
#
# **命令の意味は機種によらず同じで、違うのは文の書き方だけ**という前提を
# 守らせるためのテストです。デバイスの指し方 (`EM0:Z9`、`.L`、`.F`) は
# KV スクリプトでも ST でも同じなので、差し替えるのは文の綴りに限られます。
class TestDialect < Minitest::Test
  def kvs = FaRuby::KvsDialect.new
  def st = FaRuby::StDialect.new

  # === KV スクリプト ===

  # 生成器は KV スクリプトの形で組み立てるので、KV 向けは素通し。
  # この層を挟んでも出力が変わらないことがそのまま担保になる。
  def test_the_kv_dialect_passes_statements_through
    ["EM6:Z9 = FM0:Z1", "IF EM6:Z9 = 61 THEN", "END IF", "NEXT", "BREAK"].each do |text|
      assert_equal text, kvs.statement(text)
    end
    assert_equal "' 見出し", kvs.comment("見出し")
    assert_equal "FRSET(3)", kvs.select_bank(3)
  end

  # === ST ===

  def test_st_assignments_take_walrus_and_a_semicolon
    assert_equal "EM6:Z9 := FM0:Z1;", st.statement("EM6:Z9 = FM0:Z1")
    assert_equal "Z1 := EM0:Z9 + EM33:Z9;", st.statement("Z1 = EM0:Z9 + EM33:Z9")
  end

  # 右辺に = は現れない (比較は条件の中だけ) ので、最初の = だけを置き換える
  def test_st_replaces_only_the_first_equals
    assert_equal "EM1.L:Z1 := EM1.L:Z1 XOR EM1.L:Z2;",
                 st.statement("EM1.L:Z1 = EM1.L:Z1 XOR EM1.L:Z2")
  end

  def test_st_control_flow_uses_iec_spelling
    assert_equal "IF EM6:Z9 = 61 THEN", st.statement("IF EM6:Z9 = 61 THEN")
    assert_equal "ELSIF EM6:Z9 = 62 THEN", st.statement("ELSE IF EM6:Z9 = 62 THEN")
    assert_equal "ELSE", st.statement("ELSE")
    assert_equal "END_IF;", st.statement("END IF")
    assert_equal "FOR EM20:Z9 := 1 TO EM5:Z9 DO", st.statement("FOR EM20:Z9 = 1 TO EM5:Z9")
    assert_equal "END_FOR;", st.statement("NEXT")
    assert_equal "EXIT;", st.statement("BREAK")
  end

  # インスタンスループは刻みを指定する
  def test_st_for_with_a_step
    assert_equal "FOR Z9 := 20000 TO 22000 BY 2000 DO",
                 st.statement("FOR Z9 = 20000 TO 22000 STEP 2000")
  end

  # KV は SLA / SRA、ST は SHL / SHR。どちらでも同じ答えになるように
  # 負の値は反転して挟んであるため、名前を替えるだけでよい
  def test_st_renames_the_shift_and_negate_functions
    assert_equal "EM7:Z9 := SHL(EM8:Z9, 2);", st.statement("EM7:Z9 = SLA(EM8:Z9, 2)")
    assert_equal "EM7:Z9 := SHR(EM8:Z9, 2);", st.statement("EM7:Z9 = SRA(EM8:Z9, 2)")
    assert_equal "EM7:Z9 := -(EM8:Z9);", st.statement("EM7:Z9 = NEG(EM8:Z9)")
  end

  # ST にあるか分からないので開く。意味は同じ
  def test_st_opens_increment_into_an_assignment
    assert_equal "EM3.L:Z9 := EM3.L:Z9 + 1;", st.statement("INC(EM3.L:Z9)")
  end

  # ビットデバイスの操作は呼び出しのまま
  def test_st_keeps_calls_and_adds_a_semicolon
    assert_equal "SET(T0:Z6);", st.statement("SET(T0:Z6)")
    assert_equal "RES(MR0:Z6);", st.statement("RES(MR0:Z6)")
  end

  # **バンクを選ぶ手立てが無く、常に 0 です。** 行そのものを出さない
  def test_st_has_no_bank_selection
    assert_nil st.select_bank(3)
    assert_equal "", st.statement("FRSET(3)")
  end

  def test_st_comments_use_double_slash
    assert_equal "// 見出し", st.comment("見出し")
    assert_equal "//", st.comment("")
    assert_equal "EM0:Z9 := 0;   // PC = 0", st.statement("EM0:Z9 = 0      ' PC = 0")
  end

  # === 生成結果 ===

  # 綴り替え漏れがあると変換で落ちる。コード行に KV だけの綴りが残らないこと
  def test_the_generated_st_keeps_no_kv_only_spelling
    files = FaRuby::KvsGenerator.new(dialect: FaRuby::StDialect.new).generate
    code = files.values.flat_map { |c| c.split("\n") }
                .map(&:strip).reject { |l| l.empty? || l.start_with?("//") }

    ["FRSET", "BREAK", "NEXT", "SLA(", "SRA(", "NEG(", "INC("].each do |word|
      offenders = code.select { |l| l.include?(word) }
      assert_empty offenders.first(3), "#{word} が残っています"
    end
  end

  # 文はすべて ; か、ブロックを開く語で終わる
  def test_every_generated_st_statement_is_terminated
    files = FaRuby::KvsGenerator.new(dialect: FaRuby::StDialect.new).generate
    offenders = files.flat_map do |name, content|
      content.split("\n").each_with_index.filter_map do |line, i|
        code = line.split("//").first.to_s.strip
        next if code.empty?
        next if code.end_with?(";") || code.end_with?(" THEN") || code.end_with?(" DO")
        next if code == "ELSE"

        "#{name}:#{i + 1} #{code}"
      end
    end
    assert_empty offenders.first(5)
  end

  # **タイマ・カウンタは KV-X500 では読み取りもできません。**
  # 綴り替えでは直らないので、分岐ごと生成コードから外す
  def test_the_generated_st_has_no_timer_or_counter
    files = FaRuby::KvsGenerator.new(dialect: FaRuby::StDialect.new).generate
    offenders = files.flat_map do |name, content|
      content.split("\n").each_with_index.filter_map do |line, i|
        code = line.split("//").first.to_s
        "#{name}:#{i + 1} #{code.strip}" if code.match?(/\b[TC]0(\.[SLUDF])?:Z/)
      end
    end
    assert_empty offenders.first(5)
  end

  # KV-5000 の KV スクリプトからは外さない。読み取りはできる
  def test_the_generated_kv_script_keeps_the_timer_and_counter
    files = FaRuby::KvsGenerator.new.generate
    assert(files.values.any? { |c| c.include?("T0:Z6") }, "タイマの接点が消えています")
    assert(files.values.any? { |c| c.include?("C0.D:Z6") }, "カウンタの現在値が消えています")
  end

  def test_the_generated_st_files_carry_the_st_extension
    files = FaRuby::KvsGenerator.new(dialect: FaRuby::StDialect.new).generate
    assert(files.keys.all? { |name| name.end_with?(".st") }, files.keys.first)
    assert_equal "vm_01_init.st", files.keys.first
  end
end
