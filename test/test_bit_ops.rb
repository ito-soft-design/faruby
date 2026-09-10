# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"
require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# 整数のビット演算
#
# PLC はビットを立てたり落としたりする処理が多い。KV スクリプトの
# `AND` / `OR` / `XOR` / `NOT` はワードの演算子としてそのまま書ける。
# **条件式の連結には使えない**ので、そちらは入れ子の `IF` のまま。
# シフトは `SLA(元, 桁数, 先)` / `SRA(元, 桁数, 先)` の文。
#
# mrbc を通すため、mrbc が見つからない環境では飛ばす。
class TestBitOps < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def mrbc_path
    @mrbc_path ||= begin
      FaRuby::Config.new(nil).mrbc_path
    rescue StandardError
      nil
    end
  end

  def run_source(source)
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    dir = FaRuby::TempDir.path
    src = File.join(dir, "strings_test.rb")
    mrb = File.join(dir, "strings_test.mrb")
    File.binwrite(src, source)
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL), "mrbc に失敗"

    parser = FaRuby::MrbParser.new(File.binread(mrb))
    parser.parse
    sim = FaRuby::KvVmSimulator.new(layout: layout)
    sim.load_irep_and_run(parser.irep, max_steps: 100_000,
                          encoding: FaRuby::PlcCodegen.detect_encoding(source))
    sim
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  # シンボルだけを持つ irep (デバイステーブルの検査用)
  def irep_with(symbols)
    irep = FaRuby::Irep.new
    irep.nregs = 8
    irep.nlocals = 2
    irep.instructions = "i" # OP_STOP
    irep.ilen = irep.instructions.bytesize
    symbols.each { |s| irep.add_symbol(s) }
    irep
  end

  def status(sim) = sim.em.read_u16(layout.status_addr)
  def error(sim)  = sim.em.read_u16(layout.error_addr)

  # DM を 16 進のワード列で読む
  def words(sim, base, count)
    dm = sim.devices[DEVICE_TYPE_DM]
    (0...count).map { |i| dm.read_u16(base + i) }
  end

  # $DM0 を 16 ビット符号付きで読んで突き合わせる
  def assert_result(expected, source)
    sim = run_source(source)
    assert_finished sim
    value = sim.devices[DEVICE_TYPE_DM].read_u16(0)
    value -= 65_536 if value > 32_767
    assert_equal expected, value
  end

  def assert_finished(sim)
    assert_equal VM_FINISHED, status(sim), "実行が完了しなかった (error=#{error(sim)})"
  end

  # === ビット演算 ===
  #
  # PLC はビットを立てたり落としたりする処理が多い。KV スクリプトの
  # AND / OR / XOR / NOT はワードの演算子としてそのまま書ける

  def test_bit_and
    assert_result 8, "$DM0 = 12 & 10\n"
  end

  def test_bit_or
    assert_result 14, "$DM0 = 12 | 10\n"
  end

  def test_bit_xor
    assert_result 6, "$DM0 = 12 ^ 10\n"
  end

  # ~5 は -6。2 の補数なので符号が変わる
  def test_bit_not
    assert_result(-6, "$DM0 = ~5\n")
  end

  def test_shift_left
    assert_result 48, "$DM0 = 12 << 2\n"
  end

  def test_shift_right
    assert_result 3, "$DM0 = 12 >> 2\n"
  end

  # Ruby の >> は切り下げ。faRuby も同じ
  def test_shift_right_of_a_negative
    assert_result(-3, "$DM0 = -5 >> 1\n")
  end

  # 32 ビットで計算する。16 ビットに丸めない
  def test_a_shift_past_sixteen_bits
    sim = run_source("$DM800L = 1 << 16\n")

    assert_finished sim
    assert_equal 65_536, sim.devices[DEVICE_TYPE_DM].read_s32(800)
  end

  # 左シフトで 32 ビットからあふれると回り込む (Ruby は多倍長になる)
  def test_a_shift_that_overflows_wraps
    sim = run_source("$DM800L = 1 << 31\n")

    assert_finished sim
    assert_equal(-2_147_483_648, sim.devices[DEVICE_TYPE_DM].read_s32(800))
  end

  # ビットを立てて、見て、落とす
  def test_setting_and_clearing_a_bit
    assert_result 0, <<~RUBY
      w = 0
      w = w | 4
      w = w & ~4
      $DM0 = w
    RUBY
  end

  # 実数のビット列を触っても使い道が無い
  def test_a_float_operand_stops_the_vm
    sim = run_source("$DM0 = 2.5 & 1\n")

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::METHOD_TYPE_ERROR, error(sim)
  end

  def test_a_float_argument_stops_the_vm
    sim = run_source("$DM0 = 3 & 2.5\n")

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::METHOD_TYPE_ERROR, error(sim)
  end

  # << は整数なら左シフト、文字列と配列なら継ぎ足し
  def test_shovel_shifts_an_integer
    assert_result 20, "$DM0 = 5 << 2\n"
  end

  # 区分の検査はタグの範囲でしか見ないので、実数は本体で弾く
  def test_shovel_on_a_float_stops_the_vm
    sim = run_source("$DM0 = 2.5 << 1\n")

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::METHOD_TYPE_ERROR, error(sim)
  end

  # === シフトの端 ===
  #
  # **Ruby は桁数が負なら向きが逆になる。** 32 桁以上ずらすと左は 0、
  # 右は符号で埋まる。生成コードは SLA / SRA に範囲外の桁数を渡さないよう、
  # そこまで合わせてある

  def test_shifting_a_negative_value_left
    assert_result(-10, "$DM0 = -5 << 1\n")
  end

  # 桁数が負なら逆向き
  def test_a_negative_shift_count_reverses
    assert_result 2, "$DM0 = 5 << -1\n"
  end

  def test_a_negative_shift_count_reverses_the_other_way
    assert_result 10, "$DM0 = 5 >> -1\n"
  end

  # 32 桁以上ずらすと左は 0
  def test_shifting_left_past_the_width
    assert_result 0, "$DM0 = 5 << 32\n"
  end

  # 右は符号で埋まる
  def test_shifting_right_past_the_width
    assert_result 0, "$DM0 = 5 >> 32\n"
  end

  def test_shifting_a_negative_right_past_the_width
    assert_result(-1, "$DM0 = -5 >> 32\n")
  end

  # 桁数を実行時に決めても同じ
  def test_a_shift_count_from_a_variable
    assert_result 20, <<~RUBY
      n = 2
      $DM0 = 5 << n
    RUBY
  end

  # === 整数のビットを取る (Integer#[]) ===
  #
  # **PLC はビットを扱う場面が多いので、`(n >> i) & 1` と書かずに済ませます。**
  # `n[i]` は OP_GETIDX になり、配列や文字列と同じ命令を通ります。

  def test_a_bit_is_read_by_its_index
    assert_result 1, "$DM0 = 5[0]"
    assert_result 0, "$DM0 = 5[1]"
    assert_result 1, "$DM0 = 5[2]"
    assert_result 0, "$DM0 = 5[3]"
  end

  def test_the_index_can_come_from_a_variable
    assert_result 1, <<~RUBY
      n = 2
      $DM0 = 5[n]
    RUBY
  end

  # **上は無限に符号が続いているものとして扱う** (Ruby と同じ)
  def test_above_the_word_the_sign_bit_repeats
    assert_result 0, "$DM0 = 5[31]"
    assert_result 1, "$DM0 = -1[40]"
    assert_result 1, "$DM0 = -2[31]"
  end

  # 負の添字は 0。Ruby は例外にせずこう返す
  def test_a_negative_index_is_zero
    assert_result 0, "$DM0 = 5[-1]"
  end

  # 添字が整数でなければ止める
  def test_a_non_integer_index_stops
    sim = run_source("$DM0 = 5[1.5]")

    assert_equal VM_ERROR, status(sim)
  end

  # === 添字への複合代入 ===
  #
  # **`x[i] op= v` は `[]` と `[]=` のメソッド呼び出しになります。** 素の
  # `x[i]` が OP_GETIDX なのに複合代入だけ呼び出しになるのは mruby の出し方で、
  # そのままでは未対応のメソッドで止まります。パーサが専用命令に置き換えます。
  #
  # **ラダーの `DM0.0` に当たるものです。** インデックス修飾ではビットを
  # 指定できないので、読んで直して書く形になります。

  def test_a_bit_is_set_through_an_index
    assert_result 9, <<~RUBY
      i = 0
      $DM[i] = 1
      $DM[i] |= 1 << 3
    RUBY
  end

  def test_a_bit_is_cleared_through_an_index
    assert_result 14, <<~RUBY
      i = 0
      $DM[i] = 15
      $DM[i] &= ~(1 << 0)
    RUBY
  end

  # 同じ穴が配列とハッシュにも空いていた。まとめて塞がる
  def test_an_array_element_can_be_updated_in_place
    assert_result 15, <<~RUBY
      a = [10, 20]
      a[0] += 5
      $DM0 = a[0]
    RUBY
  end

  def test_a_hash_value_can_be_updated_in_place
    assert_result 3, <<~RUBY
      h = { "n" => 1 }
      h["n"] += 2
      $DM0 = h["n"]
    RUBY
  end

  # 置き換えるのは引数 1 個の `[]` だけ。**2 個は連続読みで意味が違う**
  def test_the_two_argument_slice_is_left_alone
    sim = run_source(<<~RUBY)
      $DM10 = 11
      $DM11 = 22
      a = $DM[10, 2]
      $DM0 = a[1]
    RUBY
    assert_finished sim
    assert_equal 22, sim.devices[DEVICE_TYPE_DM].read_u16(0)
  end

  # 置き換えた跡。長さを変えないため OP_NOP で埋める
  def test_the_send_is_replaced_in_place
    dir = FaRuby::TempDir.path
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    src = File.join(dir, "index_assign.rb")
    mrb = File.join(dir, "index_assign.mrb")
    File.binwrite(src, "a = [1]\na[0] += 1\n")
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL)
    irep = FaRuby::MrbParser.new(File.binread(mrb)).parse.irep
    names = FaRuby::Disassembler.new(irep).disassemble.map { |i| i[:name] }

    assert_includes names, :OP_GETIDX
    assert_includes names, :OP_SETIDX
    assert_includes names, :OP_NOP, "長さを合わせる埋め物"
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  # 生成コードは SLA / SRA に 0-31 しか渡さない。範囲外で何が返るか分からない
  def test_the_generated_shift_guards_the_count
    source = FaRuby::KvsGenerator.new.source
    source.scan(/S[LR]A\(.*?\)/).each do |call|
      refute_empty call, "シフトが見つからない"
    end

    guarded = source.scan(/IF (\S+) >= 32 THEN/).flatten.uniq

    refute_empty guarded, "桁数の検査が無い"
  end

end
