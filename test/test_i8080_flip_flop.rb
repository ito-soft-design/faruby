# frozen_string_literal: true

# flip_flop.rb が必要とするパターンの統合テスト
#
# flip_flop.rb で使われる言語機能を 1 つずつ確認し、
# どこで壊れているかを特定できるようにする。
#
# 実行:
#   ruby -Itools -Isimulator -Itest test/test_i8080_flip_flop.rb

require "minitest/autorun"
require "tempfile"

require_relative "../tools/i8080_bytecode_hex"
require_relative "../tools/i8080_board"
require_relative "../tools/vm_constants"

class TestI8080FlipFlop < Minitest::Test
  include FaRuby::VmConstants

  VM_HEX = File.expand_path("../plc/i8080/r8080/vm_main.hex", __dir__)

  def setup
    @mrbc = find_mrbc
    skip "mrbc not found" unless @mrbc
    skip "vm_main.hex not found" unless File.exist?(VM_HEX)
    skip "r8080 not found (R8080_PATH)" unless FaRuby::I8080Board.available?
  end

  # ============================================================
  # 1. ivar + 配列: 基本操作
  # ============================================================

  # @arr に複数要素を << で追加して読み出す (整数)
  def test_ivar_array_push_multiple_integers
    board = run_ruby(<<~RUBY)
      @arr = []
      @arr << 10
      @arr << 20
      @arr << 30
      a = @arr[0]
      b = @arr[1]
      c = @arr[2]
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 10, board[:board].reg_value(1)
    assert_equal 20, board[:board].reg_value(2)
    assert_equal 30, board[:board].reg_value(3)
  end

  # @arr に boolean を << で追加して読み出す
  def test_ivar_array_push_booleans
    board = run_ruby(<<~RUBY)
      @arr = []
      @arr << true
      @arr << false
      @arr << true
      a = @arr[0]
      b = @arr[1]
      c = @arr[2]
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_TRUE,  board[:board].reg_type(1)
    assert_equal TT_FALSE, board[:board].reg_type(2)
    assert_equal TT_TRUE,  board[:board].reg_type(3)
  end

  # ============================================================
  # 2. ivar + 配列: SETIDX
  # ============================================================

  # @states[num] = !@states[num] パターン
  def test_ivar_array_setidx
    board = run_ruby(<<~RUBY)
      @arr = []
      @arr << 10
      @arr << 20
      @arr[0] = 30
      a = @arr[0]
      b = @arr[1]
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 30, board[:board].reg_value(1)
    assert_equal 20, board[:board].reg_value(2)
  end

  # ============================================================
  # 3. boolean NOT (!) — OP_SEND :!
  # ============================================================

  def test_boolean_not_on_true
    board = run_ruby("a = true\nb = !a\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_TRUE,  board[:board].reg_type(1)
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_boolean_not_on_false
    board = run_ruby("a = false\nb = !a\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_FALSE, board[:board].reg_type(1)
    assert_equal TT_TRUE,  board[:board].reg_type(2)
  end

  # ivar 配列要素に対する NOT
  def test_ivar_array_getidx_then_not
    board = run_ruby(<<~RUBY)
      @s = []
      @s << true
      @s << false
      a = @s[0]
      b = !a
      c = @s[1]
      d = !c
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_TRUE,  board[:board].reg_type(1) # a = true
    assert_equal TT_FALSE, board[:board].reg_type(2) # b = !true
    assert_equal TT_FALSE, board[:board].reg_type(3) # c = false
    assert_equal TT_TRUE,  board[:board].reg_type(4) # d = !false
  end

  # ============================================================
  # 4. ternary (? :) — 条件分岐
  # ============================================================

  def test_ternary_true
    board = run_ruby("a = true\nb = a ? 1 : 2\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 1, board[:board].reg_value(2)
  end

  def test_ternary_false
    board = run_ruby("a = false\nb = a ? 1 : 2\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 2, board[:board].reg_value(2)
  end

  # ============================================================
  # 5. ||= パターン
  # ============================================================

  def test_or_assign_stays_false
    board = run_ruby("a = false\na ||= false\nb = a\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    # a は false のまま; b = a → R[2] = false
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_or_assign_becomes_true
    board = run_ruby("a = false\na ||= true\nb = a\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_or_assign_no_overwrite
    board = run_ruby("a = true\na ||= false\nb = a\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  # ============================================================
  # 6. each + ||= (flip_flop.rb のコア: on_any 判定)
  # ============================================================

  def test_each_or_assign_detects_true
    board = run_ruby(<<~RUBY)
      @s = []
      @s << false
      @s << false
      @s << true
      @s << false
      on_any = false
      @s.each do |f|
        on_any ||= f
      end
      a = on_any
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    # on_any=R[1], a=R[2]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_each_or_assign_all_false
    board = run_ruby(<<~RUBY)
      @s = []
      @s << false
      @s << false
      on_any = false
      @s.each do |f|
        on_any ||= f
      end
      a = on_any
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  # ============================================================
  # 7. def + ivar 参照 (print_digits パターン)
  # ============================================================

  def test_def_with_ivar_times_ternary
    board = run_ruby(<<~RUBY)
      @states = []
      @states << true
      @states << false
      @states << true
      def build
        a = ""
        3.times do |i|
          a << (@states[i] ? "#" : "o")
        end
        a
      end
      b = build
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal "#o#", board[:board].reg_string(2)
  end

  # ============================================================
  # 8. break from times ブロック
  # ============================================================

  def test_break_from_times
    board = run_ruby(<<~RUBY)
      a = 0
      10.times do |i|
        a = i
        if i == 3
          break
        end
      end
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 3, board[:board].reg_value(1)
  end

  # ============================================================
  # 9. unless (JMPIF)
  # ============================================================

  def test_unless_true
    board = run_ruby("a = 1\nunless true\n  a = 2\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 1, board[:board].reg_value(1)
  end

  def test_unless_false
    board = run_ruby("a = 1\nunless false\n  a = 2\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 2, board[:board].reg_value(1)
  end

  # ============================================================
  # 10. ivar + SETIDX + NOT (flip_flop.rb: @states[num] = !@states[num])
  # ============================================================

  def test_ivar_toggle_boolean
    board = run_ruby(<<~RUBY)
      @s = []
      @s << true
      @s << false
      @s[0] = !@s[0]
      @s[1] = !@s[1]
      a = @s[0]
      b = @s[1]
    RUBY
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal TT_FALSE, board[:board].reg_type(1) # was true → false
    assert_equal TT_TRUE,  board[:board].reg_type(2) # was false → true
  end

  # ============================================================
  # 11. LOADI16 (0x15 = 21, 1000 timeout)
  # ============================================================

  def test_loadi16
    board = run_ruby("a = 1000\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 1000, board[:board].reg_value(1)
  end

  # ============================================================
  # 12. && (短絡評価)
  # ============================================================

  def test_and_both_true
    board = run_ruby("a = true\nb = true\nc = 0\nif a && b\n  c = 1\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 1, board[:board].reg_value(3)
  end

  def test_and_first_false
    board = run_ruby("a = false\nb = true\nc = 0\nif a && b\n  c = 1\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 0, board[:board].reg_value(3)
  end

  # ============================================================
  # 13. LE 比較 (1 <= k && k <= 8)
  # ============================================================

  def test_le_comparison
    board = run_ruby("a = 3\nb = 0\nif 1 <= a && a <= 8\n  b = 1\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 1, board[:board].reg_value(2)
  end

  def test_le_out_of_range
    board = run_ruby("a = 0\nb = 0\nif 1 <= a && a <= 8\n  b = 1\nend\n")
    assert_equal :finished, board[:result], board[:board].dump_state
    assert_equal 0, board[:board].reg_value(2)
  end

  private

  # **Windows の置き場を忘れないこと。** ここに入れ忘れていたため、この
  # ファイルの 23 本が Windows では黙って飛ばされていました (他のテストは
  # 同じ mrbc で走っていたので、気づく手がかりがありませんでした)
  def find_mrbc
    candidates = [
      File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
      File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
      "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    ]
    found = candidates.find { |c| File.exist?(c) }
    return found if found

    # PATH から探す。**`> /dev/null` は Windows で「パスが見つかりません」を
    # 出すので使わない** (探索が失敗しただけなのに毎回出て紛らわしい)
    system("mrbc", "--version", out: File::NULL, err: File::NULL) ? "mrbc" : nil
  end

  def run_ruby(source, max_steps: 2_000_000)
    rb_file = Tempfile.new(["ff_test", ".rb"])
    rb_file.write(source)
    rb_file.close
    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")
    begin
      success = system(@mrbc, "-o", mrb_path, rb_file.path)
      raise "mrbc compilation failed for: #{source.inspect}" unless success
      mrb_data = File.binread(mrb_path)
      hex_gen = FaRuby::I8080BytecodeHex.new(mrb_data)
      combined = Tempfile.new(["combined", ".hex"])
      combined.write(hex_gen.generate_hex(vm_hex_path: VM_HEX))
      combined.close
      board = FaRuby::I8080Board.new
      board.load_hex(combined.path)
      result = board.run(max_steps: max_steps)
      { result: result, board: board }
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
      combined&.unlink
    end
  end
end
