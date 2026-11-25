# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../tools/i8080_board"
require_relative "../tools/i8080_bytecode_hex"

# プールの回収 (到達性を辿る)
#
# **ルートに印を付けるだけでは足りません。** 配列やハッシュの中が指す
# スロットには印が付かず、生きている文字列が配られていました。
# `a = ["keep"]` が `a[0] == "xy"` になります (エミュレータで再現済み)。
#
# PLC 版と同じ考え方に揃えました (doc/gc.md「i8080 へ戻すときの助言」)。
# ここで見るのは **PLC 版で実機でしか出なかった形**です。
#
#   1. 配列・ハッシュ・オブジェクトの中が指す文字列が残ること
#   2. **要素数 0 の配列**を生かしたまま回収させても壊れないこと
#   3. 入れ子を辿ること
#
# **プールを使い切らせるために捨てる文字列を 70 個作ります** (スロットは
# 64 個)。使い切った後は確保ごとに回収が走ります。
class TestI8080Gc < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::I8080MemoryLayout

  VM_HEX = File.expand_path("../plc/i8080/r8080/vm_main.hex", __dir__)
  MRBC_PATHS = [
    "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
    File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
  ].freeze

  def setup
    @mrbc = MRBC_PATHS.find { |p| File.executable?(p) }
    skip "mrbc not found" unless @mrbc
    skip "vm_main.hex not found" unless File.exist?(VM_HEX)
    skip "r8080 not found (R8080_PATH)" unless FaRuby::I8080Board.available?
  end

  # --- 道具 ---

  def run_ruby(source, max_steps: 5_000_000)
    rb = Tempfile.new(["gc_test", ".rb"])
    rb.write(source)
    rb.close
    mrb = rb.path.sub(/\.rb$/, ".mrb")
    begin
      assert system(@mrbc, "-o", mrb, rb.path, out: File::NULL, err: File::NULL),
             "mrbc に失敗しました"
      gen = FaRuby::I8080BytecodeHex.new(File.binread(mrb))
      combined = Tempfile.new(["gc_test", ".hex"])
      combined.write(gen.generate_hex(vm_hex_path: VM_HEX))
      combined.close

      board = FaRuby::I8080Board.new
      board.load_hex(combined.path)
      [board.run(max_steps: max_steps), board]
    ensure
      rb.unlink
      File.delete(mrb) if File.exist?(mrb)
      combined&.unlink
    end
  end

  def slot_addr(slot) = Layout::COLLECTION_POOL_BASE + slot * Layout::COL_SLOT_SIZE

  # 値スロット (4 バイト) を読む。**値は スロット + 1**
  def value_ref(board, addr)
    b = board.read_memory(addr, 4)
    { type: b[0], slot: (b[2] | (b[3] << 8)) - 1 }
  end

  # その型が入っている最初のレジスタ
  #
  # **mruby のレジスタ割り当てに寄りかからないため**、番号ではなく型で探します。
  #
  # **値 0 は飛ばします。** R0 の `main` も TT_OBJECT で、値が 0 (スロットを
  # 持たない) です。飛ばさないと探しているオブジェクトの手前で当たります
  def find_reg(board, type)
    (0...Layout::MAX_REGS).find do |i|
      board.reg_type(i) == type && board.read_u16(Layout.reg_value_addr(i)) != 0
    end
  end

  def reg_slot(board, index) = board.read_u16(Layout.reg_value_addr(index)) - 1

  # レジスタにある配列・ハッシュ・オブジェクトの中の文字列を読む
  def string_in(board, type, at:)
    reg = find_reg(board, type)
    refute_nil reg, "#{type} がレジスタに見つかりません"
    base = type == TT_OBJECT ? object_ivars(board, reg) : slot_addr(reg_slot(board, reg)) + 2
    ref = value_ref(board, base + at)
    assert_equal TT_STRING, ref[:type], "指している先が文字列ではありません (#{ref.inspect})"
    board.col_string(ref[:slot])
  end

  def object_ivars(board, reg)
    Layout::OBJECT_POOL_BASE + reg_slot(board, reg) * Layout::OBJECT_SLOT_SIZE +
      Layout::OBJECT_HEADER_SIZE
  end

  # プールを使い切らせる行
  WASTE = <<~RUBY
    70.times do
      s = "xy"
    end
  RUBY

  # --- 中が指す先が残ること ---

  def test_配列が持つ文字列は回収されない
    result, board = run_ruby("a = [\"keep\"]\n#{WASTE}b = 1\n")
    assert_equal :finished, result
    assert_equal "keep", string_in(board, TT_ARRAY, at: 0)
  end

  # **鍵は整数で書きます。** `{ k: 1 }` の形は `OP_LOADSYM` が要り、
  # i8080 では未実装 (ディスパッチ表の 10 が 0000h) なので VM が走りません
  def test_ハッシュが持つ文字列は回収されない
    result, board = run_ruby("h = { 1 => \"keep\" }\n#{WASTE}b = 1\n")
    assert_equal :finished, result
    # 組の 0 番目は 鍵 (+0) と 値 (+4)
    assert_equal "keep", string_in(board, TT_HASH, at: 4)
  end

  def test_オブジェクトのインスタンス変数が持つ文字列は回収されない
    result, board = run_ruby(<<~RUBY)
      class Holder
        def initialize
          @s = "keep"
        end
      end
      o = Holder.new
      #{WASTE.gsub(/^/, '')}
      b = 1
    RUBY
    assert_equal :finished, result
    assert_equal "keep", string_in(board, TT_OBJECT, at: 0)
  end

  def test_入れ子の配列を辿る
    result, board = run_ruby("a = [[\"keep\"]]\n#{WASTE}b = 1\n")
    assert_equal :finished, result
    outer = find_reg(board, TT_ARRAY)
    refute_nil outer
    inner = value_ref(board, slot_addr(reg_slot(board, outer)) + 2)
    assert_equal TT_ARRAY, inner[:type]
    ref = value_ref(board, slot_addr(inner[:slot]) + 2)
    assert_equal TT_STRING, ref[:type]
    assert_equal "keep", board.col_string(ref[:slot])
  end

  # --- 要素数 0 ---
  #
  # **PLC 版ではここが実機でしか出ない形でした。** 書いていない要素を値
  # スロットとして読むと、前に入っていた文字列のバイトが型タグに見えます
  def test_空の配列を生かしたまま回収しても走り切る
    result, board = run_ruby("e = []\na = [\"keep\"]\n#{WASTE}b = 1\n")
    assert_equal :finished, result
    assert_equal 0, board.vm_error_code
  end

  # --- 回収そのもの ---

  def test_使い切っても止まらない
    result, board = run_ruby("#{WASTE}b = 7\n")
    assert_equal :finished, result
    assert_equal 0, board.vm_error_code
  end
end
