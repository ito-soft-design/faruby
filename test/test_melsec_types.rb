# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"
require_relative "../tools/melsec_types"
require_relative "../tools/melsec_typecheck"
require_relative "../tools/kvs_generator"

# 三菱の型合わせ
#
# **GX Works2 は型をまたぐ代入も比較も通しません。** KV は黙って広げてくれた
# ので、命令の定義には整数と実数を直に比べる箇所も、16 ビットを 32 ビットへ
# そのまま入れる箇所もあります。変換にかけるまで分からないと 1 往復ごとに
# 1 件しか潰せないので、ここで全部見ます。
class TestMelsecTypes < Minitest::Test
  def layout = FaRuby::Config.new.for_model("Q").layout

  # === 生成物 ===

  # **これが本題です。** 生成した ST に型の食い違いが残っていないこと
  def test_the_generated_st_has_no_type_mismatch
    findings = FaRuby::MelsecTypecheck.new(layout: layout).findings
    report = findings.first(5).map { |f| "#{f.file}:#{f.line} #{f.reason}\n    #{f.text}" }

    assert_empty report, "型が合っていません (全 #{findings.size} 件)"
  end

  # **GX Works2 は文の無い分岐を通しません。** KV スクリプトでも KV-X500 の
  # ST でも通るので、生成器は `OP_NOP` や「ここへは来ない」の分岐を注釈だけで
  # 閉じています。綴り方が最後に何もしない代入を置きます。
  def test_no_branch_is_left_empty
    generator = FaRuby::KvsGenerator.new(layout: layout, dialect: FaRuby::MelsecDialect.new)
    offenders = generator.generate.flat_map do |name, content|
      next [] unless name.end_with?(".st")

      empty_branches(name, content)
    end

    assert_empty offenders.first(5)
  end

  # 開いたまま次の分岐に入る行を拾う
  def empty_branches(name, content)
    opened = nil
    content.split("\n").each_with_index.filter_map do |line, i|
      code = line.split("(*").first.to_s.strip
      found = "#{name}:#{opened + 1}" if opened && closes?(code)
      opened = nil if !code.empty? && !opens?(code)
      opened = i if opens?(code)
      found
    end
  end

  def opens?(code) = code.end_with?("THEN") || code.end_with?("DO") || code == "ELSE"
  def closes?(code) = code.start_with?("ELSIF", "END_") || code == "ELSE"

  # **`FOR` の制御変数には代入できません。** ループの中で代入すると
  # 「1 番目の引数に不正な値」で止まります (実機で確認済み)
  #
  # 1 本にまとめたときにステップのループがループカウンタを使うようになり、
  # 中身の無い分岐に置いた自己代入がそこを踏みました。
  # **開いているループの変数だけを見ます。** Z レジスタはループの変数にも
  # 算法の一時変数にも使うので、そのループの外なら代入して構いません。
  def test_no_loop_variable_is_assigned
    source = FaRuby::KvsGenerator.new(layout: layout, dialect: FaRuby::MelsecDialect.new).source
    open = []
    offenders = source.split("\n").each_with_index.filter_map do |line, i|
      code = line.split("(*").first.to_s.strip
      open.pop if code.start_with?("END_FOR")
      found = "#{i + 1}: #{code}" if open.any? { |name| code.start_with?("#{name} :=") }
      open << Regexp.last_match(1) if code =~ /\AFOR\s+([A-Z][A-Z0-9]*)\s*:=/
      found
    end

    assert_empty offenders.first(5), "回っているループの変数に代入しています"
  end

  # **実数と整数は比べられません。** `VMSLOTF[i].SLNUM <> 0` は通らない
  def test_a_real_compares_against_a_real_literal
    assert_equal "IF VMTEMP32F <> 0.0 THEN", types.coerce("IF VMTEMP32F <> 0 THEN")
    assert_equal "VMTEMP32F := 0.0;", types.coerce("VMTEMP32F := 0;")
  end

  # **16 ビットのビット列は符号付きで書きます。** INT は 65408 が入らない
  #
  # 生成器が置くのは -Infinity の上位ワード (0xFF80) といったビット列で、
  # 数の大きさに意味はありません。KV の EM は符号なしでした。
  def test_a_word_pattern_is_written_signed
    assert_equal "VMPC := -128;", types.coerce("VMPC := 65408;")
    assert_equal "VMPC := 32640;", types.coerce("VMPC := 32640;")
  end

  # 32 ビットには収まるので、そのまま
  def test_a_long_keeps_the_same_number
    assert_equal "VMTEMP32L := VMTEMP32L + 65536;", types.coerce("VMTEMP32L := VMTEMP32L + 65536;")
  end

  # 添字の中は整数のまま。レジスタ番号を実数にしても意味がない
  def test_the_index_stays_an_integer_next_to_a_real
    assert_equal "VMSLOTF[VMREGSLOT + 2].SLNUM := 0.0;",
                 types.coerce("VMSLOTF[VMREGSLOT + 2].SLNUM := 0;")
  end

  # === 規則 ===

  def types
    labels = {
      "VMPC" => label("VMPC", "ワード[符号付き]"),
      "VMTEMP32L" => label("VMTEMP32L", "ダブルワード[符号付き]"),
      "VMTEMP32F" => label("VMTEMP32F", "単精度実数"),
    }
    FaRuby::MelsecTypes.new(labels, FaRuby::DeviceSet.melsec)
  end

  def label(name, type) = FaRuby::MelsecDevices::Label.new(name, type, "D4000", "")

  # 16 ビットを 32 ビットへ入れるところは広げる
  def test_a_narrow_value_widens_on_assignment
    assert_equal "VMTEMP32L := INT_TO_DINT(VMPC);", types.coerce("VMTEMP32L := VMPC;")
  end

  # 逆は狭める。**入りきらない値は落ちますが、KV も同じです**
  def test_a_wide_value_narrows_on_assignment
    assert_equal "VMPC := DINT_TO_INT(VMTEMP32L);", types.coerce("VMPC := VMTEMP32L;")
  end

  # 合っていれば触らない
  def test_a_matching_assignment_is_left_alone
    assert_equal "VMPC := 1;", types.coerce("VMPC := 1;")
    assert_equal "VMTEMP32L := 1;", types.coerce("VMTEMP32L := 1;")
  end

  # **式ごと包まずに項ごとに変換します。** 外から包んでも中は直りません
  def test_each_term_converts_on_its_own
    assert_equal "VMTEMP32L := VMTEMP32L + INT_TO_DINT(VMPC);",
                 types.coerce("VMTEMP32L := VMTEMP32L + VMPC;")
  end

  # 比べるときは狭いほうを広げる
  def test_a_comparison_widens_the_narrow_side
    assert_equal "IF INT_TO_DINT(VMPC) < VMTEMP32L THEN",
                 types.coerce("IF VMPC < VMTEMP32L THEN")
    assert_equal "ELSIF DINT_TO_REAL(VMTEMP32L) > VMTEMP32F THEN",
                 types.coerce("ELSIF VMTEMP32L > VMTEMP32F THEN")
  end

  # **添字は 16 ビットのままです。** レジスタ番号を広げても意味がありません
  def test_the_index_is_left_alone
    assert_equal "VMTEMP32L := VMSLOT[VMPC + 1].SLNUM;",
                 types.coerce("VMTEMP32L := VMSLOT[VMPC + 1].SLNUM;")
  end

  # ビットデバイスは変換の相手にならない
  def test_a_bit_device_is_left_alone
    assert_equal "M0Z6 := TRUE;", types.coerce("M0Z6 := TRUE;")
  end

  # 末尾のコメントは触らない
  def test_the_trailing_comment_survives
    assert_equal "VMTEMP32L := INT_TO_DINT(VMPC);   (* 見出し *)",
                 types.coerce("VMTEMP32L := VMPC;   (* 見出し *)")
  end
end
