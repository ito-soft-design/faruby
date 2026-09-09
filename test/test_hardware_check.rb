# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/hardware_check"

# 実機確認の見出しの読み取り
#
# **プログラムの見出しがそのまま期待値です。** 別に表を持つと、片方だけ
# 直して気づかない形になります。ここで見るのは読み取りだけで、実行には
# PLC が要ります (`rake hw`)。
class TestHardwareCheck < Minitest::Test
  Check = FaRuby::HardwareCheck

  # === 期待値 ===

  def test_expectations_are_read_from_the_heading
    source = <<~RUBY
      # 見出し
      #
      # 期待値:
      #   $DM120 = 1       説明
      #   $DM121 = -2
      #
      # 実機でのみ意味を持つ検証。

      $DM120 = 1
    RUBY

    assert_equal [["DM120", 1], ["DM121", -2]], Check.expectations(source)
  end

  # 幅サフィックス付きと実数
  def test_expectations_keep_the_width_suffix_and_read_floats
    source = "# 期待値:\n#   $DM520F = 3.0\n#   $DM526 = 3\n"

    assert_equal [["DM520F", 3.0], ["DM526", 3]], Check.expectations(source)
  end

  # 見出しが終わったら止める。本文の代入を期待値と間違えないこと
  def test_expectations_stop_at_the_end_of_the_heading
    source = "# 期待値:\n#   $DM120 = 1\n\n$DM121 = 2\n"

    assert_equal [["DM120", 1]], Check.expectations(source)
  end

  def test_a_program_without_a_heading_has_no_expectations
    assert_empty Check.expectations("a = 1\nb = 2\n")
  end

  # === 対象機種 ===

  # **タイマ・カウンタは KV-X500 で使えません。** 機種を書いておけば飛ばせる
  def test_the_models_line_limits_the_program
    source = "# 対象機種: KV-5000\n#\n# 期待値:\n#   $DM126 = 0\n"

    assert_equal ["KV-5000"], Check.models(source)
  end

  def test_several_models_can_be_listed
    assert_equal %w[KV-5000 KV-X500], Check.models("# 対象機種: KV-5000, KV-X500\n")
  end

  # 書かなければどの機種でも走らせる
  def test_without_the_line_the_program_runs_anywhere
    assert_nil Check.models("# 見出し\n# 期待値:\n#   $DM120 = 1\n")
  end

  # === プログラム ===

  # 見出しの機種名が綴り間違いだと黙って飛ばされ続ける
  def test_every_models_line_names_a_model_we_have
    bad = Dir[File.join(Check::PROGRAM_DIR, "*.rb")].filter_map do |path|
      models = Check.models(File.read(path, encoding: "utf-8"))
      next unless models

      unknown = models - FaRuby::Dialect.models
      "#{File.basename(path)}: #{unknown.join(', ')}" unless unknown.empty?
    end

    assert_empty bad
  end
end
