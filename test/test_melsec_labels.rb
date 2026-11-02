# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/kvs_generator"
require_relative "../tools/config"

# 三菱のラベル表
#
# **ラッチした領域のラベルは保持クラスでないと変換が通りません** (GX Works3)。
# GX Works2 にはこの検査がありませんでした。
class TestMelsecLabels < Minitest::Test
  # ラベルを割り付けたデバイス。見出し行を除くために中身で見る
  #
  # **列の位置では拾えません。** GX Works2 と GX Works3 で列が違い、
  # 見出しの数も同じではありません (Q で見出しを拾って気づきました)。
  DEVICE = /\A[A-Z]+\d+\z/

  # 機種のラベル表を [クラス, 名前, 割付け先] で返す
  def labels(model)
    dialect = FaRuby::Dialect.for(model)
    layout = FaRuby::Config.defaults.for_model(model).layout
    generator = FaRuby::KvsGenerator.new(layout: layout, dialect: dialect)
    files = generator.generate
    name = files.keys.find { |k| k.include?("Global") }
    refute_nil name, "#{model}: ラベル表が無い"

    files.fetch(name).lines.filter_map do |line|
      cells = line.split("\t").map { |c| c.delete('"').strip }
      device = cells.find { |c| c.match?(DEVICE) }
      next unless device && cells.first.start_with?("VAR_")

      [cells.first, cells[1], device]
    end
  end

  # **iQ-R は D も ZR もラッチにしてあります** (PLC パラメータの保存領域設定)
  def test_the_iqr_retains_every_label_on_a_latched_device
    on_latched = labels("iQ-R").select { |_, _, device| device.match?(/\A(D|ZR)\d/) }

    refute_empty on_latched
    on_latched.each do |klass, name, device|
      assert_equal "VAR_GLOBAL_RETAIN", klass,
                   "#{name} (#{device}) が保持クラスでない (GX Works3 の変換が通らない)"
    end
  end

  # **特殊リレーは入れません。** ラッチの範囲ではなくシステムのデバイスです
  def test_special_relays_stay_plain_globals
    specials = labels("iQ-R").select { |_, _, device| device.start_with?("SM") }

    refute_empty specials, "SM のラベルが無い (クロックパルスを使っている)"
    specials.each do |klass, name, device|
      assert_equal "VAR_GLOBAL", klass, "#{name} (#{device}) を保持にしてはいけない"
    end
  end

  # **Q は分ける必要がありません。** GX Works2 はこの検査をしません
  def test_the_q_uses_plain_globals_throughout
    labels("Q").each do |klass, name, device|
      assert_equal "VAR_GLOBAL", klass, "#{name} (#{device}) が VAR_GLOBAL でない"
    end
  end
end
