# frozen_string_literal: true

require "minitest/autorun"
require "set"

# i8080 アセンブリの飛び先が全部解決すること
#
# **asm80 が無くても走ります。** アセンブラを持っていない環境でも、
# 書き間違えた飛び先はここで分かります。
#
# アセンブルすれば未定義ラベルは当然落ちますが、**この表の .hex は
# コミットされていて、アセンブラを入れていない環境でもテストが走ります。**
# その環境で「書いたつもりのラベル」が実在するかを見る手が無いので、
# ここで見ます。
class TestI8080Labels < Minitest::Test
  ASM_DIR = File.expand_path("../plc/i8080/r8080", __dir__)

  # 飛び先を取る命令
  #
  # 条件付きも含めて全部。`rst` と `pchl` は番地やレジスタなので見ません。
  JUMPS = /^\s*(?:jmp|jz|jnz|jc|jnc|jp|jm|jpe|jpo|call|cz|cnz|cc|cnc|cp|cm|cpe|cpo)\s+(\S+)/i

  # 数値の番地 (16 進・10 進)
  NUMERIC = /\A(?:[0-9][0-9A-Fa-f]*h|[0-9]+|0x[0-9A-Fa-f]+)\z/

  def sources = Dir[File.join(ASM_DIR, "*.a80")].sort

  # ラベル定義。行頭の `名前:`
  def labels
    @labels ||= sources.each_with_object({}) do |path, acc|
      File.readlines(path, encoding: "UTF-8").each_with_index do |line, i|
        m = line.match(/^([A-Za-z_][A-Za-z0-9_]*):/) or next
        acc[m[1].downcase] ||= "#{File.basename(path)}:#{i + 1}"
      end
    end
  end

  # EQU で定義した名前も飛び先になり得る (モニタの入口など)
  def equates
    @equates ||= sources.each_with_object(Set.new) do |path, acc|
      File.readlines(path, encoding: "UTF-8").each do |line|
        m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s+EQU\s/i) or next
        acc << m[1].downcase
      end
    end
  end

  def jump_targets
    @jump_targets ||= sources.flat_map do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?(";")

        code = line.split(";", 2).first.to_s
        m = code.match(JUMPS) or next
        { target: m[1].sub(/,$/, ""), where: "#{File.basename(path)}:#{i + 1}",
          text: code.strip }
      end
    end
  end

  def test_ラベル定義が読めている
    refute_empty labels, "ラベルを 1 つも読めませんでした (#{ASM_DIR})"
    assert_includes labels.keys, "col_gc_alloc"
  end

  def test_飛び先が読めている
    refute_empty jump_targets, "jmp / call を 1 つも読めませんでした"
  end

  # **書き間違えた飛び先はアセンブルするまで分かりません。** 0000h と
  # 同じように素通りするので、ここで止めます
  def test_どの飛び先も解決する
    unresolved = jump_targets.reject do |j|
      t = j[:target].downcase
      labels.key?(t) || equates.include?(t) || j[:target].match?(NUMERIC)
    end

    assert_empty unresolved.map { |j| "#{j[:where]}  #{j[:text]}" },
                 "解決しない飛び先があります"
  end

  # 同じ名前を 2 か所で定義していないこと (後から書いた方が勝って静かに壊れる)
  def test_ラベルが重複していない
    seen = {}
    dups = []
    sources.each do |path|
      File.readlines(path, encoding: "UTF-8").each_with_index do |line, i|
        m = line.match(/^([A-Za-z_][A-Za-z0-9_]*):/) or next
        key = m[1].downcase
        where = "#{File.basename(path)}:#{i + 1}"
        if seen[key]
          dups << "#{m[1]} (#{seen[key]} と #{where})"
        else
          seen[key] = where
        end
      end
    end

    assert_empty dups, "同じラベルを 2 度定義しています"
  end
end
