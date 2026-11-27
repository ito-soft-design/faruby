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
    # **隣に r8080 が無い環境では飛ばします。** 上の 2 つと同じ扱いで、
    # PLC だけを触る環境でも rake test:plc と rake test が通るように
    skip "r8080 not found (R8080_PATH)" unless FaRuby::I8080Board.available?
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

  def test_break_from_until_inside_times
    # OP_JMPUW: ブロック (times) 内の until から break
    board = run_ruby(<<~RUBY)
      a = 0
      3.times do
        n = 0
        until n == 5
          break if n == 3
          n = n + 1
        end
        a = a + n
      end
    RUBY
    assert_equal :finished, board[:result]
    # n は毎回 3 で break → a = 3 + 3 + 3 = 9
    assert_equal 9, board[:board].reg_value(1)
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

  # === ユーザー定義メソッド ===

  def test_def_basic
    # def double(n); n + n; end; a = double(3)
    board = run_ruby(<<~RUBY)
      def double(n)
        n + n
      end
      a = double(3)
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 6, board[:board].reg_value(1)
  end

  def test_def_two_methods
    board = run_ruby(<<~RUBY)
      def add1(n)
        n + 1
      end
      def add2(n)
        n + 2
      end
      a = add1(10) + add2(20)
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 33, board[:board].reg_value(1)
  end

  # === クラス定義 ===

  def test_class_def_and_method
    board = run_ruby(<<~RUBY)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
      end
      a = Counter.new(3).value
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(1)
  end

  def test_class_two_objects
    board = run_ruby(<<~RUBY)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
      end
      a = Counter.new(3)
      b = Counter.new(8)
      c = a.value + b.value
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 11, board[:board].reg_value(3)
  end

  def test_class_bump
    board = run_ruby(<<~RUBY)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
        def bump
          @n = @n + 1
          @n
        end
      end
      a = Counter.new(5)
      a.bump
      a.bump
      c = a.value
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 7, board[:board].reg_value(3)
  end

  def test_class_isolation
    # トップレベルの def value と クラスの def value が混在しない
    board = run_ruby(<<~RUBY)
      class Foo
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
      end
      def value
        99
      end
      a = value
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 99, board[:board].reg_value(1)
  end

  def test_class_method_call
    # メソッド内から自分のメソッド呼び出し
    board = run_ruby(<<~RUBY)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
        def twice
          value + value
        end
      end
      a = Counter.new(6).twice
    RUBY
    assert_equal :finished, board[:result]
    assert_equal 12, board[:board].reg_value(1)
  end

  # === display / getkey ビルトイン ===

  def test_display_builtin
    # display(a) で 7 セグに hex 002A を表示
    # 末尾に a を置いて OP_RETURN R[1] でも同じ値を表示させる
    board = run_ruby("a = 42\ndisplay(a)\na\n")
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(1)
    assert_equal "    002A", board[:board].display_text
  end

  def test_display_builtin_zero
    # display(0) → 0000, OP_RETURN R[1]=nil の値=0 でも 0000
    board = run_ruby("display(0)\n")
    assert_equal :finished, board[:result]
    assert_equal "    0000", board[:board].display_text
  end

  def test_display_builtin_variable
    # 変数を介して display を呼ぶ
    board = run_ruby("a = 255\ndisplay(a)\na\n")
    assert_equal :finished, board[:result]
    assert_equal "    00FF", board[:board].display_text
  end

  def test_getkey_simulator
    # シミュレータでは ROM なし → -1 が返る
    board = run_ruby("a = getkey\n")
    assert_equal :finished, board[:result]
    assert_equal(-1, board[:board].reg_value(1))
  end

  def test_getkey_timeout_simulator
    # シミュレータでは ROM なし → nil が返る
    board = run_ruby("a = getkey(100)\n")
    assert_equal :finished, board[:result]
    assert_equal TT_NIL, board[:board].reg_type(1)
  end

  # === puts (ASCII → 7 セグ表示) ===

  def test_puts_basic
    # puts がクラッシュせず nil を返すことを確認
    board = run_ruby("puts(0x4131)\n")
    assert_equal :finished, board[:result]
  end

  def test_puts_display
    # puts(0x4131) → 'A'(0x77) と '1'(0x06) を右端 2 桁に表示 (整数パス)
    # loop で表示を保持 (OP_RETURN による上書きを防ぐ)
    board = run_ruby("puts(0x4131)\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x77, raw[6], "digit 6 should be 'A' pattern"
    assert_equal 0x06, raw[7], "digit 7 should be '1' pattern"
    # 左 6 桁は初期値 (0x00) のままスクロール
    (0..5).each { |i| assert_equal 0x00, raw[i], "digit #{i} should be blank" }
  end

  def test_puts_scroll
    # 2 回の puts でスクロールを確認 (整数パス)
    # puts(0x4142) → "AB", puts(0x4344) → "CD"
    # スクロール後: 左 4 桁ブランク, [4]=A(0x77), [5]=B(0x7C), [6]=C(0x39), [7]=D(0x5E)
    board = run_ruby("puts(0x4142)\nputs(0x4344)\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x00, raw[0]
    assert_equal 0x00, raw[1]
    assert_equal 0x00, raw[2]
    assert_equal 0x00, raw[3]
    assert_equal 0x77, raw[4], "digit 4 should be 'A' pattern"
    assert_equal 0x7C, raw[5], "digit 5 should be 'B' pattern"
    assert_equal 0x39, raw[6], "digit 6 should be 'C' pattern"
    assert_equal 0x5E, raw[7], "digit 7 should be 'D' pattern"
  end

  def test_puts_lowercase_fold
    # 小文字は大文字に折り畳まれる (整数パス)
    # puts(0x6131) = 'a'→'A', '1'→'1'
    board = run_ruby("puts(0x6131)\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x77, raw[6], "lowercase 'a' should fold to 'A' pattern"
    assert_equal 0x06, raw[7], "'1' pattern"
  end

  # === puts 文字列リテラル (OP_STRING → TT_STRING パス) ===

  def test_puts_string_hi
    # puts "HI" → 左詰め: H(0x76), I(0x06), 残りブランク
    board = run_ruby("puts \"HI\"\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x76, raw[0], "digit 0 should be 'H' pattern"
    assert_equal 0x06, raw[1], "digit 1 should be 'I' pattern"
    (2..7).each { |i| assert_equal 0x00, raw[i], "digit #{i} should be blank" }
  end

  def test_puts_string_hello
    # puts "HELLO" → H(0x76), E(0x79), L(0x38), L(0x38), O(0x5C), blank×3
    board = run_ruby("puts \"HELLO\"\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x76, raw[0], "H"
    assert_equal 0x79, raw[1], "E"
    assert_equal 0x38, raw[2], "L"
    assert_equal 0x38, raw[3], "L"
    assert_equal 0x5C, raw[4], "O"
    (5..7).each { |i| assert_equal 0x00, raw[i], "digit #{i} should be blank" }
  end

  def test_puts_string_lowercase_fold
    # puts "hello" → 小文字は大文字に折り畳まれる
    board = run_ruby("puts \"hello\"\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x76, raw[0], "h → H"
    assert_equal 0x79, raw[1], "e → E"
    assert_equal 0x38, raw[2], "l → L"
    assert_equal 0x38, raw[3], "l → L"
    assert_equal 0x5C, raw[4], "o → O"
  end

  def test_puts_string_digits
    # puts "1234" → 数字のセグメントパターン
    board = run_ruby("puts \"1234\"\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x06, raw[0], "'1'"
    assert_equal 0x5B, raw[1], "'2'"
    assert_equal 0x4F, raw[2], "'3'"
    assert_equal 0x66, raw[3], "'4'"
  end

  def test_puts_string_inside_loop
    # 回帰テスト: 文字列リテラルがループ本体 (子 irep) のプールにある場合
    # (programs/test_builtin.rb の実機テストパターン)
    board = run_ruby("loop do\nputs \"HELLO\"\nbreak\nend\n")
    assert_equal :finished, board[:result]
    # break 後に OP_RETURN で上書きされるが、クラッシュしないことが重要
  end

  # === setseg (任意パターン設定) ===

  def test_setseg_basic
    # setseg(7, 0x77) → DISPLAY_BASE+7 に 0x77 を書く
    board = run_ruby("setseg(7, 119)\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x77, raw[7], "digit 7 should have pattern 0x77"
  end

  def test_setseg_position_0
    # setseg(0, 63) → DISPLAY_BASE+0 に 0x3F を書く
    board = run_ruby("setseg(0, 63)\nloop do\nend\n", max_steps: 100_000)
    assert_equal :timeout, board[:result]
    raw = board[:board].display_raw
    assert_equal 0x3F, raw[0], "digit 0 should have pattern 0x3F"
  end

  # === rand (擬似乱数) ===

  def test_rand_returns_integer
    board = run_ruby("a = rand(10)\n")
    assert_equal :finished, board[:result]
    val = board[:board].reg_value(1)
    assert_operator val, :>=, 0
    assert_operator val, :<, 10
  end

  def test_rand_one
    # rand(1) は常に 0 を返す
    board = run_ruby("a = rand(1)\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(1)
  end

  def test_rand_zero
    # rand(0) はエッジケース → 0 を返す
    board = run_ruby("a = rand(0)\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(1)
  end

  def test_rand_within_range
    # 複数回呼んで全て範囲内
    board = run_ruby("a = rand(6)\nb = rand(6)\nc = rand(6)\n")
    assert_equal :finished, board[:result]
    [1, 2, 3].each do |r|
      val = board[:board].reg_value(r)
      assert_operator val, :>=, 0, "R[#{r}] = #{val} should be >= 0"
      assert_operator val, :<, 6, "R[#{r}] = #{val} should be < 6"
    end
  end

  # === 文字列操作テスト ===

  def test_string_length
    board = run_ruby("a = \"hello\"\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal TT_INTEGER, board[:board].reg_type(2)
    assert_equal 5, board[:board].reg_value(2)
  end

  def test_string_size
    board = run_ruby("a = \"abc\"\nb = a.size\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(2)
  end

  def test_string_getidx
    board = run_ruby("a = \"abc\"\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(2)
    assert_equal "b", board[:board].reg_string(2)
  end

  def test_string_concat_str
    board = run_ruby("a = \"ab\"\na << \"cd\"\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(1)
    assert_equal "abcd", board[:board].reg_string(1)
  end

  def test_string_strcat
    board = run_ruby("a = \"ab\" + \"cd\"\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(1)
    assert_equal "abcd", board[:board].reg_string(1)
  end

  def test_string_puts
    # puts with string literal should still work (compatibility)
    # Note: OP_STOP overwrites display with return value, so we only check :finished
    board = run_ruby("puts \"HELLO\"\n")
    assert_equal :finished, board[:result]
  end

  def test_string_empty
    board = run_ruby("a = \"\"\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(2)
  end

  # === 配列操作テスト ===

  def test_array_literal
    board = run_ruby("a = [1, 2, 3]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_ARRAY, board[:board].reg_type(1)
    assert_equal [1, 2, 3], board[:board].reg_array(1)
  end

  def test_array_getidx
    board = run_ruby("a = [10, 20, 30]\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_INTEGER, board[:board].reg_type(2)
    assert_equal 20, board[:board].reg_value(2)
  end

  def test_array_setidx
    board = run_ruby("a = [1, 2, 3]\na[1] = 99\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal 99, board[:board].reg_value(2)
  end

  def test_array_push
    board = run_ruby("a = [1]\na.push(2)\n")
    assert_equal :finished, board[:result]
    assert_equal [1, 2], board[:board].reg_array(1)
  end

  def test_array_concat
    board = run_ruby("a = [1]\na << 2\n")
    assert_equal :finished, board[:result]
    assert_equal [1, 2], board[:board].reg_array(1)
  end

  def test_array_length
    board = run_ruby("a = [1, 2, 3]\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(2)
  end

  def test_array_empty
    board = run_ruby("a = []\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(2)
  end

  # === Hash テスト ===

  def test_hash_literal
    board = run_ruby("a = {1 => 2}\n")
    assert_equal :finished, board[:result]
    assert_equal TT_HASH, board[:board].reg_type(1)
    assert_equal({1 => 2}, board[:board].reg_hash(1))
  end

  def test_hash_getidx
    board = run_ruby("a = {1 => 10}\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_INTEGER, board[:board].reg_type(2)
    assert_equal 10, board[:board].reg_value(2)
  end

  def test_hash_getidx_not_found
    board = run_ruby("a = {1 => 10}\nb = a[2]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_NIL, board[:board].reg_type(2)
  end

  def test_hash_setidx
    board = run_ruby("a = {1 => 10}\na[1] = 99\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal 99, board[:board].reg_value(2)
  end

  def test_hash_setidx_append
    board = run_ruby("a = {1 => 10}\na[2] = 20\nb = a[2]\n")
    assert_equal :finished, board[:result]
    assert_equal 20, board[:board].reg_value(2)
  end

  def test_hash_length
    board = run_ruby("a = {1 => 10, 2 => 20}\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 2, board[:board].reg_value(2)
  end

  def test_hash_empty
    board = run_ruby("a = {}\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(2)
  end

  # --- 文字列スライス (2 引数 []) ---

  def test_string_slice_basic
    board = run_ruby("a = \"abcdef\"\nb = a[1, 3]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(2)
    assert_equal "bcd", board[:board].reg_string(2)
  end

  def test_string_slice_clamp
    # length が残りバイト数を超える場合はクランプ
    board = run_ruby("a = \"abc\"\nb = a[1, 8]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(2)
    assert_equal "bc", board[:board].reg_string(2)
  end

  def test_string_slice_scroll
    # test_builtin.rb パターン: 9 文字から [1,8] で先頭を削る
    board = run_ruby("a = \"abcdefgh\"\na << \"i\"\na = a[1, 8]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(1)
    assert_equal "bcdefghi", board[:board].reg_string(1)
  end

  def test_string_slice_empty
    # offset == 文字列長 → 空文字列
    board = run_ruby("a = \"abc\"\nb = a[3, 2]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(2)
    assert_equal "", board[:board].reg_string(2)
  end

  # --- each ---

  def test_each_basic
    # 配列の要素を合計する
    src = <<~RUBY
      a = [10, 20, 30]
      sum = 0
      a.each do |x|
        sum = sum + x
      end
      b = sum
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 60, board[:board].reg_value(3)
  end

  def test_each_empty
    # 空配列の each はブロックを実行しない
    src = <<~RUBY
      a = []
      sum = 99
      a.each do |x|
        sum = 0
      end
      b = sum
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 99, board[:board].reg_value(3)
  end

  def test_each_boolean
    # flip_flop.rb パターン: 配列内の true/false を検査
    src = <<~RUBY
      a = [false, false, true, false]
      found = false
      a.each do |f|
        found = true if f
      end
      b = found
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  def test_each_single
    # 要素 1 つの配列
    board = run_ruby("a = [42]\nb = 0\na.each do |x|\n  b = x\nend\nc = b\n")
    assert_equal :finished, board[:result]
    assert_equal 42, board[:board].reg_value(3)
  end

  # --- ハッシュの each ---
  #
  # **ブロックには鍵と値の 2 つを渡します。** 配列の each と同じフレームの
  # 数え方 (見出しの +1 が反復の回数) で、違うのは渡す値だけです。

  def test_hash_each_keys_and_values
    # 鍵と値をそれぞれ合計する
    src = <<~RUBY
      h = {1 => 10, 2 => 20}
      ks = 0
      vs = 0
      h.each do |k, v|
        ks = ks + k
        vs = vs + v
      end
      a = ks
      b = vs
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal 3, board[:board].reg_value(4)
    assert_equal 30, board[:board].reg_value(5)
  end

  def test_hash_each_empty
    # 空ハッシュの each はブロックを実行しない
    src = <<~RUBY
      h = {}
      n = 99
      h.each do |k, v|
        n = 0
      end
      a = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 99, board[:board].reg_value(2)
  end

  def test_hash_each_single
    # ペア 1 つ。鍵と値が入れ違っていないこと
    src = <<~RUBY
      h = {7 => 42}
      kk = 0
      vv = 0
      h.each do |k, v|
        kk = k
        vv = v
      end
      a = kk
      b = vv
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 7, board[:board].reg_value(4)
    assert_equal 42, board[:board].reg_value(5)
  end

  def test_hash_each_full
    # 容量いっぱいの 4 ペア (COL_MAX_HASH_PAIRS)
    src = <<~RUBY
      h = {1 => 1, 2 => 2, 3 => 4, 4 => 8}
      n = 0
      h.each do |k, v|
        n = n + v
      end
      a = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 15, board[:board].reg_value(2)
  end

  def test_hash_each_breaks
    # break は反復を打ち切り、その値が呼び出しの値になる
    src = <<~RUBY
      h = {1 => 10, 2 => 20}
      n = 0
      h.each do |k, v|
        n = v
        break
      end
      a = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 10, board[:board].reg_value(2)
  end

  # **配列の each を壊していないこと。** 同じ枝を通るようにしたので、
  # ハッシュを足したときに配列側が静かに変わっていないかを見ます
  def test_hash_each_does_not_disturb_array_each
    src = <<~RUBY
      a = [1, 2, 3]
      h = {4 => 5}
      n = 0
      a.each do |x|
        n = n + x
      end
      h.each do |k, v|
        n = n + k + v
      end
      b = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 15, board[:board].reg_value(3)
  end

  # --- any? / all? / none? ---
  #
  # **新しいのはブロックの戻り値を見ることだけです。** 渡す値は each と
  # 同じで、配列かハッシュかはスロットの見出し (COL_TYPE_*) で決まります。
  # 答えは R[0] (レシーバの位置) に書きます — 打ち切る瞬間はもう要素を
  # 取り出さないので、レシーバを潰してよいためです。

  # --- ブロック無し ---
  #
  # **`a.all?` は `a.all? { |x| x }` と同じです。** 中身をそのまま返す
  # ブロック (恒等ブロック) を渡したものとして each の道に入れるので、
  # 反復もフレームも判定もブロック付きと同じ経路です。恒等ブロックは
  # `OP_RETURN R[1]` の 2 バイトで、**ホストがブロック無しの述語を
  # 見つけたときだけ**最後の irep として足します (番号は
  # IDENTITY_IREP_STORE)。
  #
  # **ハッシュは反復しません。** Ruby はブロック無しのとき `[鍵, 値]` の
  # 配列を見るので中身によらず常に真で、組の数だけで決まります。

  def test_blockless_all_true
    board = run_ruby("a = [1, 2]\nb = a.all?\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_blockless_all_false
    board = run_ruby("a = [1, nil]\nb = a.all?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_blockless_any_true
    board = run_ruby("a = [nil, 1]\nb = a.any?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_blockless_any_false
    board = run_ruby("a = [nil, false]\nb = a.any?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_blockless_none_true
    board = run_ruby("a = [nil, false]\nb = a.none?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_blockless_none_false
    board = run_ruby("a = [nil, 1]\nb = a.none?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  # 0 は Ruby では真
  def test_blockless_any_treats_zero_as_true
    board = run_ruby("a = [0]\nb = a.any?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  # 空は 1 回も回らないので、フレームを積まずに答えが決まる
  def test_blockless_on_empty_array
    board = run_ruby("a = Array.new(0)\nb = a.all?\nc = a.any?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
    assert_equal TT_FALSE, board[:board].reg_type(3)
  end

  # ハッシュは [鍵, 値] を見るので、鍵が偽でも all? は真
  def test_blockless_hash_all_is_always_true
    board = run_ruby("h = Hash.new\nh[1] = 5\nb = h.all?\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_blockless_hash_none_is_false_when_filled
    board = run_ruby("h = Hash.new\nh[1] = 5\nb = h.none?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_blockless_empty_hash
    board = run_ruby("h = Hash.new\nb = h.any?\nc = h.none?\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  # **恒等ブロックは最後の irep。** 使っているときだけ足す
  def test_identity_block_is_the_last_irep
    gen = compile_to_hex_gen("a = [1]\nb = a.all?\n")
    ireps = gen.all_ireps

    assert_equal [56, 1], ireps.last.instructions.bytes, "OP_RETURN R[1]"
    assert_equal ireps.size - 1,
                 gen.build_memory[FaRuby::I8080MemoryLayout::IDENTITY_IREP_STORE],
                 "箱に入っている番号が最後の irep"
  end

  def test_identity_block_is_absent_without_a_blockless_call
    gen = compile_to_hex_gen("a = [1]\nb = a.all? { |x| x }\n")

    refute_equal [56, 1], gen.all_ireps.last.instructions.bytes,
                 "ブロック付きに恒等ブロックを足してはいけない"
    assert_equal 0, gen.build_memory[FaRuby::I8080MemoryLayout::IDENTITY_IREP_STORE],
                 "0 は「恒等ブロックは無い」"
  end

  def compile_to_hex_gen(source)
    rb = Tempfile.new(["ib", ".rb"])
    rb.write(source)
    rb.close
    mrb = rb.path.sub(/\.rb$/, ".mrb")
    system(@mrbc, "-o", mrb, rb.path) or raise "mrbc 失敗"
    FaRuby::I8080BytecodeHex.new(File.binread(mrb))
  ensure
    rb.unlink
    File.delete(mrb) if mrb && File.exist?(mrb)
  end

  def test_any_true
    board = run_ruby("a = [1, 2, 3]\nb = a.any? { |x| x == 2 }\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_any_false
    board = run_ruby("a = [1, 2, 3]\nb = a.any? { |x| x == 9 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_any_empty_is_false
    board = run_ruby("a = []\nb = a.any? { |x| true }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  # 打ち切っていること。全部回ると 6 になる
  def test_any_stops_at_the_first_hit
    src = <<~RUBY
      n = 0
      a = [1, 2, 3]
      a.any? do |x|
        n = n + x
        x == 2
      end
      b = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(3)
  end

  def test_all_true
    board = run_ruby("a = [2, 4]\nb = a.all? { |x| x > 1 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_all_false
    board = run_ruby("a = [2, 0]\nb = a.all? { |x| x > 1 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_all_empty_is_true
    board = run_ruby("a = []\nb = a.all? { |x| false }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_none_true
    board = run_ruby("a = [1, 2]\nb = a.none? { |x| x == 9 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_none_false
    board = run_ruby("a = [1, 2]\nb = a.none? { |x| x == 2 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  # **0 も真です。** nil と false だけが偽
  def test_predicate_treats_zero_as_true
    board = run_ruby("a = [1]\nb = a.any? { |x| 0 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_predicate_treats_nil_as_false
    board = run_ruby("a = [1]\nb = a.any? { |x| nil }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_hash_any_sees_key_and_value
    board = run_ruby("h = {1 => 10, 2 => 20}\nb = h.any? { |k, v| v == 20 }\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_hash_all_
    board = run_ruby("h = {1 => 10, 2 => 0}\nb = h.all? { |k, v| v > 5 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_FALSE, board[:board].reg_type(2)
  end

  def test_hash_none_
    board = run_ruby("h = {1 => 10}\nb = h.none? { |k, v| k > 9 }\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  # 入れ子。内側の判定が外側に漏れないこと
  def test_nested_any
    src = <<~RUBY
      a = [1, 2]
      c = [8, 9]
      b = a.any? do |x|
        c.any? { |y| x + y == 11 }
      end
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(3)
  end

  # --- Array.new / Hash.new ---
  #
  # **`Array` は組み込みクラスとして登録します。** 利用者の定数にすると
  # 未代入のスロットになり、`.new` が型違いで止まります。型タグは
  # `TT_BUILTIN_CLASS` で、`new` の中で作るものが違います。
  #
  # 容量は 1 スロット **8 要素**です (PLC は 12)。

  # **`.nil?` は値として書けません。** 条件式の中なら mruby が畳みますが、
  # 値にすると `OP_SEND :nil?` になり、組み込みに無いので止まります
  def test_array_new_size_only
    board = run_ruby("a = Array.new(3)\nb = a.length\nc = a[0] ? 1 : 2\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal 3, board[:board].reg_value(2)
    assert_equal 2, board[:board].reg_value(3)
  end

  def test_array_new_no_args
    board = run_ruby("a = Array.new\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(2)
  end

  def test_array_new_with_value
    board = run_ruby("a = Array.new(3, 7)\nb = a[0]\nc = a[2]\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal 7, board[:board].reg_value(2)
    assert_equal 7, board[:board].reg_value(3)
  end

  def test_array_new_with_true
    board = run_ruby("a = Array.new(2, true)\nb = a[1]\n")
    assert_equal :finished, board[:result]
    assert_equal TT_TRUE, board[:board].reg_type(2)
  end

  def test_array_new_with_block
    src = <<~RUBY
      a = Array.new(3) { |i| i * 10 }
      b = a[0]
      c = a[1]
      d = a[2]
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal 0, board[:board].reg_value(2)
    assert_equal 10, board[:board].reg_value(3)
    assert_equal 20, board[:board].reg_value(4)
  end

  def test_array_new_block_zero_rounds
    src = <<~RUBY
      n = 99
      a = Array.new(0) { n = 0 }
      b = a.length
      c = n
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].reg_value(3)
    assert_equal 99, board[:board].reg_value(4)
  end

  # **break は打ち切って値をそのまま返す** (Ruby と同じ)
  def test_array_new_block_break
    board = run_ruby("r = Array.new(3) { break 5 }\n")
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(1)
  end

  def test_array_new_block_reads_outer
    src = <<~RUBY
      n = 0
      a = Array.new(3) { |i| n = n + 1 }
      b = a[2]
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 3, board[:board].reg_value(3)
  end

  # **8 要素が上限** (COL_MAX_ARRAY_ELEMS)
  def test_array_new_at_capacity
    board = run_ruby("a = Array.new(8, 1)\nb = a.length\n")
    assert_equal :finished, board[:result]
    assert_equal 8, board[:board].reg_value(2)
  end

  # **大きさは変数で渡します。** 定数で書くと書き込む前に止まり
  # (`check_array_new_sizes`)、実行時の枝を通りません
  def test_array_new_over_capacity_stops
    board = run_ruby("n = 9\na = Array.new(n)\n")
    refute_equal :finished, board[:result]
  end

  def test_array_new_negative_stops
    board = run_ruby("n = -1\na = Array.new(n)\n")
    refute_equal :finished, board[:result]
  end

  # 書き込む前に止まる側
  def test_array_new_literal_over_capacity_is_refused
    assert_raises(RuntimeError) { run_ruby("a = Array.new(9)\n") }
  end

  def test_hash_new_is_empty
    board = run_ruby("h = Hash.new\nb = h.length\n")
    assert_equal :finished, board[:result]
    assert_equal 0, board[:board].vm_error_code
    assert_equal 0, board[:board].reg_value(2)
  end

  def test_hash_new_then_used
    board = run_ruby("h = Hash.new\nh[1] = 5\nb = h[1]\n")
    assert_equal :finished, board[:result]
    assert_equal 5, board[:board].reg_value(2)
  end

  # **既定値は未対応** — 覚える場所が無い (見出しの空きが 2 バイト)
  def test_hash_new_with_default_stops
    board = run_ruby("h = Hash.new(0)\n")
    refute_equal :finished, board[:result]
  end

  # 利用者のクラスの new を壊していないこと
  def test_user_class_new_still_works
    src = <<~RUBY
      class Holder
        def initialize(v)
          @v = v
        end

        def v
          @v
        end
      end
      a = Holder.new(7).v
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal 7, board[:board].reg_value(1)
  end

  # --- GC (コレクションプール回収) ---

  def test_gc_string_loop
    # 10 回ループで毎回 slice + string literal → GC なしなら 20+ スロット必要
    # GC が不要スロットを回収するので MAX_COL_SLOTS=16 でも動く
    src = <<~RUBY
      a = "abcdefgh"
      10.times do
        a << "z"
        a = a[1, 8]
      end
      b = a
    RUBY
    board = run_ruby(src)
    assert_equal :finished, board[:result]
    assert_equal TT_STRING, board[:board].reg_type(2)
    assert_equal "ghzzzzzzzz"[2, 8], board[:board].reg_string(2)
  end

  # --- バンク切り替え ---

  def test_bank_no_clone_without_rom
    # ROM データなし → クローンスキップ → 通常動作
    r = run_ruby("a = 42\n")
    assert_equal :finished, r[:result]
    assert_equal 42, r[:board].reg_value(1)
  end

  def test_bank_rom_write_protection
    # BankedMemory の ROM 保護: ROM バンク選択時は書き込みが無視される
    board = FaRuby::I8080Board.new(banked: true)
    board.load_rom_data(0x0000, [0xC3, 0x00, 0x00])
    # bank_bit=false (ROM 選択) のとき ROM が読める
    board.instance_variable_get(:@memory).bank_bit = false
    assert_equal [0xC3, 0x00, 0x00], board.read_memory(0x0000, 3)
    # ROM バンク選択時、書き込みは無視される
    board.write_memory(0x0000, [0xFF, 0xFF, 0xFF])
    assert_equal [0xC3, 0x00, 0x00], board.read_memory(0x0000, 3)
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

    # PATH から探す。**`> /dev/null` は Windows で「パスが見つかりません」を
    # 出すので使わない**
    system("mrbc", "--version", out: File::NULL, err: File::NULL) ? "mrbc" : nil
  end

  # Ruby ソースをコンパイルして i8080 VM で実行する
  def run_ruby(source, max_steps: 2_000_000)
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
      result = board.run(max_steps: max_steps)

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

  # Ruby ソースをバンク切り替え対応モードで実行する
  def run_ruby_banked(source, max_steps: 2_500_000, rom_data: {})
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

      board = FaRuby::I8080Board.new(banked: true)
      rom_data.each { |addr, bytes| board.load_rom_data(addr, bytes) }
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
