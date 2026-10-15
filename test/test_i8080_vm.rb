# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../tools/i8080_bytecode_hex"
require_relative "../tools/i8080_board"
require_relative "../tools/vm_constants"

# i8080 バックエンド統合テスト
#
# mrbc でコンパイルしたバイトコードを i8080 VM で実行し、
# レジスタと 7 セグ表示の結果を検証します。
#
# 依存:
#   - mrbc (mruby コンパイラ)
#   - r8080 (i8080 エミュレータ)
#   - asm80 でアセンブル済みの vm_main.hex
class TestI8080Vm < Minitest::Test
  include FaRuby::VmConstants

  VM_HEX = File.expand_path("../plc/i8080/r8080/vm_main.hex", __dir__)

  def setup
    @mrbc = find_mrbc
    skip "mrbc not found" unless @mrbc
    skip "vm_main.hex not found" unless File.exist?(VM_HEX)
  end

  # === 基本テスト ===

  def test_literal_3
    board = run_ruby("a = 3\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(1)
  end

  def test_addition
    board = run_ruby("a = 1 + 2\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(1)
    assert_equal "    0003", board[:board].display_text
  end

  def test_subtraction
    board = run_ruby("a = 10 - 3\n")
    assert_equal :finished, board[:result]
    assert_equal 7, board[:board].reg_value(1)
  end

  # mrbc は定数式を畳むため、変数を介して OP_ADD / OP_SUB を使わせる
  def test_add_via_variables
    board = run_ruby("a = 100\nb = 37\nc = a + b\n")
    assert_equal :finished, board[:result]
    assert_equal 137, board[:board].reg_value(3)
  end

  def test_sub_via_variables
    board = run_ruby("a = 100\nb = 37\nc = a - b\n")
    assert_equal :finished, board[:result]
    assert_equal 63, board[:board].reg_value(3)
  end

  # OP_ADDI / OP_SUBI (即値加減算)
  def test_addi
    board = run_ruby("a = 5\nb = a + 10\n")
    assert_equal :finished, board[:result]
    assert_equal 15, board[:board].reg_value(2)
  end

  def test_subi
    board = run_ruby("a = 20\nb = a - 7\n")
    assert_equal :finished, board[:result]
    assert_equal 13, board[:board].reg_value(2)
  end

  # === 乗算・除算 ===

  def test_mul_basic
    board = run_ruby("a = 3\nb = 4\nc = a * b\n")
    assert_equal :finished, board[:result]
    assert_equal 12, board[:board].reg_value(3)
  end

  def test_mul_by_zero
    board = run_ruby("a = 5\nb = 0\nc = a * b\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(3)
  end

  def test_mul_negative
    board = run_ruby("a = -3\nb = 4\nc = a * b\n")
    assert_equal :finished, board[:result]
    assert_equal(-12, board[:board].reg_value(3))
  end

  def test_mul_large
    board = run_ruby("a = 100\nb = 200\nc = a * b\n")
    assert_equal :finished, board[:result]
    assert_equal 20_000, board[:board].reg_value(3)
  end

  def test_div_basic
    board = run_ruby("a = 10\nb = 3\nc = a / b\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(3)
  end

  def test_div_exact
    board = run_ruby("a = 12\nb = 4\nc = a / b\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(3)
  end

  def test_div_negative_floor
    # Ruby の整数除算は floor (負の無限大方向): -7 / 2 = -4
    board = run_ruby("a = -7\nb = 2\nc = a / b\n")
    assert_equal :finished, board[:result]
    assert_equal(-4, board[:board].reg_value(3))
  end

  def test_div_by_one
    board = run_ruby("a = 42\nb = 1\nc = a / b\n")
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(3)
  end

  # === グローバル変数 ===

  def test_global_var_set_get
    board = run_ruby("$foo = 42\na = $foo + 8\n")
    assert_equal :finished, board[:result]
    assert_equal 50, board[:board].reg_value(1)
  end

  def test_global_var_multiple
    board = run_ruby("$x = 10\n$y = 20\na = $x + $y\n")
    assert_equal :finished, board[:result]
    assert_equal 30, board[:board].reg_value(1)
  end

  def test_global_var_overwrite
    board = run_ruby("$g = 5\n$g = $g + 3\na = $g\n")
    assert_equal :finished, board[:result]
    assert_equal 8, board[:board].reg_value(1)
  end

  # === インスタンス変数 ===

  def test_instance_var_set_get
    board = run_ruby("@count = 42\na = @count + 8\n")
    assert_equal :finished, board[:result]
    assert_equal 50, board[:board].reg_value(1)
  end

  def test_instance_var_overwrite
    board = run_ruby("@n = 0\n@n = @n + 1\na = @n\n")
    assert_equal :finished, board[:result]
    assert_equal 1, board[:board].reg_value(1)
  end

  def test_instance_var_and_global_separate
    board = run_ruby("$x = 10\n@x = 20\na = $x + @x\n")
    assert_equal :finished, board[:result]
    assert_equal 30, board[:board].reg_value(1)
  end

  # === メソッド呼び出し (SEND/SSEND) ===

  def test_send_ne_true
    board = run_ruby(<<~RUBY)
      a = 5
      b = 6
      if a != b
        c = 1
      else
        c = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 1, board[:board].reg_value(3)
  end

  def test_send_ne_false
    board = run_ruby(<<~RUBY)
      a = 5
      b = 5
      if a != b
        c = 1
      else
        c = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 2, board[:board].reg_value(3)
  end

  def test_send_not_nil
    board = run_ruby(<<~RUBY)
      a = nil
      b = 0
      if !a
        b = 1
      else
        b = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 1, board[:board].reg_value(2)
  end

  def test_send_not_true
    board = run_ruby(<<~RUBY)
      a = true
      b = 0
      if !a
        b = 1
      else
        b = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 2, board[:board].reg_value(2)
  end

  def test_send_mod_basic
    board = run_ruby(<<~RUBY)
      a = 7
      b = 3
      c = a % b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 1, board[:board].reg_value(3)
  end

  def test_send_mod_floor
    # Ruby の剰余は除数と同符号 (floor modulo): -7 % 3 = 2
    board = run_ruby(<<~RUBY)
      a = -7
      b = 3
      c = a % b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 2, board[:board].reg_value(3)
  end

  def test_send_abs_negative
    board = run_ruby(<<~RUBY)
      a = -5
      b = a.abs
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(2)
  end

  def test_send_abs_positive
    board = run_ruby(<<~RUBY)
      a = 5
      b = a.abs
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(2)
  end

  def test_loadi_0_through_7
    # OP_LOADI_0 〜 OP_LOADI_7 がそれぞれ正しい値を返す
    (0..7).each do |n|
      board = run_ruby("a = #{n}\n")
      assert_equal :finished, board[:result], "LOADI_#{n}"
      assert_equal n, board[:board].reg_value(1), "LOADI_#{n}"
    end
  end

  def test_loadi_small
    board = run_ruby("a = 42\n")
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(1)
  end

  def test_loadi_255
    board = run_ruby("a = 255\n")
    assert_equal :finished, board[:result]
    assert_equal 255, board[:board].reg_value(1)
  end

  def test_loadi16
    board = run_ruby("a = 1000\n")
    assert_equal :finished, board[:result]
    assert_equal 1000, board[:board].reg_value(1)
  end

  def test_negative_literal
    board = run_ruby("a = -5\n")
    assert_equal :finished, board[:result]
    assert_equal(-5, board[:board].reg_value(1))
  end

  def test_negative_result
    board = run_ruby("a = 3 - 10\n")
    assert_equal :finished, board[:result]
    assert_equal(-7, board[:board].reg_value(1))
  end

  # === nil / true / false ===

  def test_loadnil
    board = run_ruby("a = nil\n")
    assert_equal :finished, board[:result]
    assert_equal TT_NIL, board[:board].reg_type(1)
  end

  def test_loadt
    board = run_ruby("a = true\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(1)
  end

  def test_loadf
    board = run_ruby("a = false\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(1)
  end

  # === MOVE ===

  def test_move
    board = run_ruby("a = 42\nb = a\n")
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(1)
    assert_equal 42, board[:board].reg_value(2)
  end

  # === 比較 ===

  def test_eq_true
    board = run_ruby(<<~RUBY)
      a = 5
      b = 5
      c = a == b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  def test_eq_false
    board = run_ruby(<<~RUBY)
      a = 5
      b = 6
      c = a == b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(3)
  end

  def test_lt_true
    board = run_ruby(<<~RUBY)
      a = 3
      b = 5
      c = a < b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  def test_lt_false
    board = run_ruby(<<~RUBY)
      a = 5
      b = 3
      c = a < b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(3)
  end

  def test_gt
    board = run_ruby(<<~RUBY)
      a = 10
      b = 3
      c = a > b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  def test_le
    board = run_ruby(<<~RUBY)
      a = 5
      b = 5
      c = a <= b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  def test_ge
    board = run_ruby(<<~RUBY)
      a = 3
      b = 5
      c = a >= b
    RUBY
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(3)
  end

  # === 分岐 ===

  def test_if_true_branch
    board = run_ruby(<<~RUBY)
      a = 5
      b = 0
      if a > 3
        b = 1
      else
        b = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 1, board[:board].reg_value(2)
  end

  def test_if_false_branch
    board = run_ruby(<<~RUBY)
      a = 1
      b = 0
      if a > 3
        b = 1
      else
        b = 2
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 2, board[:board].reg_value(2)
  end

  def test_while_loop
    board = run_ruby(<<~RUBY)
      a = 0
      i = 0
      while i < 5
        a = a + i
        i = i + 1
      end
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 10, board[:board].reg_value(1)  # 0+1+2+3+4 = 10
    assert_equal 5,  board[:board].reg_value(2)   # i = 5
  end

  # === 7 セグ表示 ===

  def test_display_zero
    board = run_ruby("a = 0\n")
    assert_equal :finished, board[:result]
    assert_equal "    0000", board[:board].display_text
  end

  def test_display_hex
    board = run_ruby("a = 255\n")
    assert_equal :finished, board[:result]
    assert_equal "    00FF", board[:board].display_text
  end

  def test_display_large
    board = run_ruby("a = 4096\n")
    assert_equal :finished, board[:result]
    assert_equal "    1000", board[:board].display_text
  end

  # === ブロック (times / loop) ===

  def test_times_basic
    # 3.times { |i| @sum = @sum + i } → @sum = 0+1+2 = 3
    board = run_ruby(<<~RUBY)
      @sum = 0
      3.times { |i| @sum = @sum + i }
      a = @sum
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(1)
  end

  def test_times_five
    # 5.times { |i| @sum = @sum + i } → @sum = 0+1+2+3+4 = 10
    board = run_ruby(<<~RUBY)
      @sum = 0
      5.times { |i| @sum = @sum + i }
      a = @sum
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 10, board[:board].reg_value(1)
  end

  def test_times_zero
    # 0.times は本体を実行しない
    board = run_ruby(<<~RUBY)
      @n = 42
      0.times { |i| @n = 0 }
      a = @n
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(1)
  end

  def test_loop_break
    board = run_ruby(<<~RUBY)
      @n = 0
      loop do
        break if @n > 4
        @n = @n + 1
      end
      a = @n
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(1)
  end

  def test_times_upvar
    # ブロック内から外側のローカル変数にアクセス (GETUPVAR / SETUPVAR)
    board = run_ruby(<<~RUBY)
      a = 0
      5.times { a = a + 1 }
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(1)
  end

  # === SimVm との相互検証 ===
  #
  # 同じ Ruby プログラムを SimVm と i8080 VM で実行し、
  # レジスタの値が一致することを確認します。

  def test_cross_check_with_sim_vm
    skip "SimVm not available" unless sim_vm_available?

    programs = [
      "a = 1 + 2\n",
      "a = 100 - 37\n",
      "a = -5\nb = a + 10\n",
      "a = 0\ni = 0\nwhile i < 10\n  a = a + i\n  i = i + 1\nend\n",
    ]

    programs.each do |source|
      i8080_result = run_ruby(source)
      sim_result = run_sim_vm(source)

      assert_equal :finished, i8080_result[:result], "i8080 VM should finish: #{source.inspect}"

      # R[1] の値を比較 (最初の変数)
      i8080_val = i8080_result[:board].reg_value(1)
      sim_val = sim_result.reg(1)
      assert_equal sim_val, i8080_val,
                   "R[1] mismatch for: #{source.inspect} (sim=#{sim_val}, i8080=#{i8080_val})"
    end
  end

  private

  def find_mrbc
    candidates = [
      File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
      File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
      "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    ]
    found = candidates.find { |c| File.exist?(c) }
    return found if found

    # PATH から探す
    system("mrbc --version > /dev/null 2>&1") ? "mrbc" : nil
  end

  # Ruby ソースをコンパイルして i8080 VM で実行する
  def run_ruby(source)
    rb_file = Tempfile.new(["i8080_test", ".rb"])
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
      result = board.run

      { result: result, board: board }
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
      combined&.unlink
    end
  end

  # SimVm が使える場合に限り相互検証を行う
  def sim_vm_available?
    require_relative "../simulator/kv_vm_simulator"
    true
  rescue LoadError
    false
  end

  def run_sim_vm(source)
    require_relative "../simulator/kv_vm_simulator"

    rb_file = Tempfile.new(["sim_test", ".rb"])
    rb_file.write(source)
    rb_file.close
    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")

    begin
      system(@mrbc, "-o", mrb_path, rb_file.path)
      parser = FaRuby::MrbParser.new(File.binread(mrb_path)).parse
      sim = FaRuby::KvVmSimulator.new
      sim.load_irep_and_run(parser.irep)
      sim
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
    end
  end
end
