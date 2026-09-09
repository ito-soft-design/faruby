# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/benchmark"

# 実行速度の計測
#
# **測るループを変えると前の数字と並べられなくなります。** 1 度それで
# 足をすくわれているので、1 周の命令数を持たせて実測と突き合わせます。
# ここで見るのは計算だけで、実行には PLC が要ります (`rake bench`)。
class TestBenchmark < Minitest::Test
  Bench = FaRuby::Benchmark

  def result(rates:, steps_per_loop: 4.0, expected: 4, steps_per_cycle: 50)
    Bench::Result.new("OP_ADDI", "説明", rates, steps_per_loop, expected, steps_per_cycle)
  end

  # === 数字の出し方 ===

  # ばらつきは他の負荷を拾ったぶんなので、速い方を採る
  def test_the_fastest_round_is_the_answer
    assert_in_delta 40_000, result(rates: [38_000, 40_000, 39_000]).rate, 0.001
  end

  def test_the_scan_period_is_the_budget_divided_by_the_rate
    r = result(rates: [50_000])

    assert_in_delta 1.0, r.scan_ms, 0.001      # 50 命令 / 50,000 命令毎秒 = 1 ms
    assert_in_delta 20.0, r.micros_per_step, 0.001
  end

  def test_the_spread_is_reported_as_a_percentage
    assert_in_delta 5.0, result(rates: [95.0, 100.0]).spread, 0.001
  end

  # === 1 周の命令数 ===

  # 前提どおりなら、前に測った数字と並べてよい
  def test_the_expected_step_count_holds
    assert result(rates: [1.0], steps_per_loop: 4.001, expected: 4).steps_match?
  end

  # **変わったら知らせる。**黙って別の数字になるのがいちばん困る
  def test_a_changed_step_count_is_caught
    refute result(rates: [1.0], steps_per_loop: 9.0, expected: 4).steps_match?
  end

  # === 測るループ ===

  # 変えないためのもの。**うっかり足すときに目に入る**ように数だけ見る
  #
  # **ループはどの機種でも同じで、周回数の置き場だけが違います。**
  # 置き場を渡すと本文が組み上がります。
  def test_the_loops_are_fixed_and_declare_what_they_cost
    assert_equal %w[OP_ADDI OP_ADD], Bench::LOOPS.map(&:name)
    Bench::LOOPS.each do |target|
      assert_operator target.steps_per_loop, :>, 0, target.name
      source = target.source.call("DM660")
      assert_includes source, "while true", target.name
      assert_includes source, "DM660", target.name
    end
  end

  # 置き場はメーカーごと。**接続の設定と綴りが揃っていること**
  def test_every_protocol_has_a_counter
    assert_equal %w[keyence_kv mitsubishi_mc], Bench::COUNTERS.keys
    Bench::COUNTERS.each_value do |device, addr|
      refute_empty device
      assert_match(/\A\d+\z/, addr)
    end
  end
end
