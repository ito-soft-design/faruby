# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# Array.new / Hash.new
#
# **`Array` は組み込みクラスとして登録します。** `OP_CLASS` に出てこない
# 大文字の名前は利用者の定数になるので、外さないと未代入の値スロットになり、
# `.new` がレシーバの型違いで止まります。
#
# 型タグは `TT_BUILTIN_CLASS` で、利用者のクラス (`TT_CLASS`) とは別です。
# **`new` で作るものが違い、メソッド表の行も持たない**ためです。
# `new` の受け手の検査はタグ 13-14 の 1 範囲で済みます。
#
# ブロック形 `Array.new(8) { |i| }` は**新しい反復**です。渡すのは添字
# (`times` と同じ) で、ブロックの値を要素へ書きます。**`any?` で作った
# 「ブロックの値を見る」仕組みがそのまま使えます。**
class TestArrayNew < Minitest::Test
  include FaRuby::VmConstants
  # エラーコードは命令の定義側にあります
  include FaRuby::OpcodeTable

  MRBC_PATHS = [
    "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
    File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
  ].freeze

  def setup
    @mrbc = MRBC_PATHS.find { |p| File.executable?(p) }
    skip "mrbc not found" unless @mrbc
  end

  def layout = FaRuby::MemoryLayout.default

  def compile(source)
    Dir.mktmpdir do |dir|
      rb = File.join(dir, "a.rb")
      mrb = File.join(dir, "a.mrb")
      File.write(rb, source, encoding: "utf-8")
      assert system(@mrbc, "-o", mrb, rb, out: File::NULL, err: File::NULL),
             "mrbc に失敗しました"
      return FaRuby::MrbParser.new(File.binread(mrb)).parse.irep
    end
  end

  def run_source(source)
    sim = FaRuby::KvVmSimulator.new
    sim.load_irep_and_run(compile(source), max_steps: 200_000)
    sim
  end

  def dm(sim, index) = sim.devices[DEVICE_TYPE_DM].read_s16(index)
  def error_of(sim) = sim.em.read_u16(layout.error_addr)

  def assert_finished(sim)
    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 0, error_of(sim)
  end

  def assert_values(source, expected)
    sim = run_source(source)
    assert_finished(sim)
    assert_equal expected, (0...expected.size).map { |i| dm(sim, i) }
  end

  def assert_stops_with(source, error)
    sim = run_source(source)
    assert_equal VM_ERROR, sim.status, "止まらなかった"
    assert_equal error, error_of(sim)
  end

  # --- 大きさだけ ---

  def test_大きさだけなら_nil_で埋まる
    assert_values(<<~RUBY, [3, 1, 1])
      a = Array.new(3)
      $DM0 = a.length
      $DM1 = a[0].nil? ? 1 : 0
      $DM2 = a[2].nil? ? 1 : 0
    RUBY
  end

  def test_引数なしは空配列
    assert_values("a = Array.new\n$DM0 = a.length\n", [0])
  end

  def test_0_個は空配列
    assert_values("a = Array.new(0)\n$DM0 = a.length\n", [0])
  end

  # --- 既定値 ---

  def test_既定値で埋まる
    assert_values(<<~RUBY, [3, 7, 7])
      a = Array.new(3, 7)
      $DM0 = a.length
      $DM1 = a[0]
      $DM2 = a[2]
    RUBY
  end

  def test_既定値は真偽値でもよい
    assert_values(<<~RUBY, [1, 1])
      a = Array.new(2, true)
      $DM0 = a[0] ? 1 : 0
      $DM1 = a[1] ? 1 : 0
    RUBY
  end

  # **同じスロット番号が入ります** (Ruby と同じ落とし穴)
  def test_既定値の配列は共有される
    assert_values(<<~RUBY, [1, 9])
      inner = [1]
      a = Array.new(2, inner)
      a[0].push(9)
      $DM0 = a[1][0]
      $DM1 = a[1][1]
    RUBY
  end

  # --- ブロック形 ---

  def test_ブロックは添字を受ける
    assert_values(<<~RUBY, [3, 0, 10, 20])
      a = Array.new(3) { |i| i * 10 }
      $DM0 = a.length
      $DM1 = a[0]
      $DM2 = a[1]
      $DM3 = a[2]
    RUBY
  end

  def test_ブロックの値が要素になる
    assert_values(<<~RUBY, [1, 1])
      a = Array.new(2) { true }
      $DM0 = a[0] ? 1 : 0
      $DM1 = a[1] ? 1 : 0
    RUBY
  end

  def test_ブロック形も_0_個なら回らない
    assert_values(<<~RUBY, [0, 99])
      n = 99
      a = Array.new(0) { n = 0 }
      $DM0 = a.length
      $DM1 = n
    RUBY
  end

  # **break は打ち切って値をそのまま返します** (Ruby と同じ)
  def test_ブロックの_break_は値になる
    assert_values(<<~RUBY, [5])
      r = Array.new(3) { break 5 }
      $DM0 = r
    RUBY
  end

  def test_ブロックは外側の変数を読み書きできる
    assert_values(<<~RUBY, [3, 2])
      n = 0
      a = Array.new(3) { |i| n = n + 1 }
      $DM0 = a.length
      $DM1 = a[1]
    RUBY
  end

  # --- Hash ---

  def test_hash_new_は空ハッシュ
    assert_values("h = Hash.new\n$DM0 = h.length\n", [0])
  end

  def test_hash_new_のあとは普通のハッシュ
    assert_values(<<~RUBY, [5, 1])
      h = Hash.new
      h[1] = 5
      $DM0 = h[1]
      $DM1 = h.length
    RUBY
  end

  # **既定値は未対応です。** 覚える場所が無い (見出しの空きが 1 ワード)
  def test_hash_new_は引数を取れない
    assert_stops_with("h = Hash.new(0)\n", UNKNOWN_METHOD_ERROR)
  end

  # --- 止まるもの ---

  def test_容量を超える大きさは止まる
    assert_stops_with("a = Array.new(#{layout.max_array_len + 1})\n", HEAP_ERROR)
  end

  def test_ブロック形も容量で止まる
    assert_stops_with("a = Array.new(#{layout.max_array_len + 1}) { 1 }\n",
                      HEAP_ERROR)
  end

  def test_大きさが整数でなければ止まる
    assert_stops_with("a = Array.new(true)\n", METHOD_TYPE_ERROR)
  end

  def test_負の大きさは止まる
    assert_stops_with("a = Array.new(-1)\n", METHOD_TYPE_ERROR)
  end

  def test_引数が_3_つは止まる
    assert_stops_with("a = Array.new(1, 2, 3)\n", UNKNOWN_METHOD_ERROR)
  end

  # **利用者のクラスにブロックは渡せません。** Ruby は initialize へ渡しますが
  # faRuby はブロック引数を持ちません
  def test_利用者のクラスにブロックを渡すと止まる
    assert_stops_with(<<~RUBY, METHOD_TYPE_ERROR)
      class Counter
        def v
          1
        end
      end
      c = Counter.new { 1 }
    RUBY
  end

  # --- ほかを壊していないこと ---

  def test_利用者のクラスの_new_はそのまま
    assert_values(<<~RUBY, [7])
      class Holder
        def initialize(v)
          @v = v
        end

        def v
          @v
        end
      end
      $DM0 = Holder.new(7).v
    RUBY
  end

  def test_配列リテラルと_each_はそのまま
    assert_values(<<~RUBY, [6, 3])
      a = [1, 2, 3]
      n = 0
      a.each { |x| n = n + x }
      $DM0 = n
      $DM1 = a.length
    RUBY
  end

  # --- 回収との組み合わせ ---
  #
  # **使い切ってから作らせます。** 確保の経路が増えたので、回収が走る側でも
  # 要素が nil で埋まっていることを見ます
  def test_プールを使い切っても作れる
    assert_values(<<~RUBY, [4, 1])
      keep = [1]
      40.times do
        t = Array.new(4)
      end
      a = Array.new(4, 1)
      $DM0 = a.length
      $DM1 = a[3]
    RUBY
  end
end
