# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../tools/i8080_board"
require_relative "../tools/i8080_bytecode_hex"

# 定数とクラス変数 (i8080)
#
# **PLC 側と同じ考え方です。** どちらもグローバル変数と同じ 4 バイトの
# スロットに入ります。足したのはディスパッチ表の 3 本
# (`OP_GETCV` / `OP_SETCV` / `OP_SETCONST` を `OP_GETGV` / `OP_SETGV` へ) と、
# `do_op_getconst` の種別による振り分けだけです。
#
# **直した不具合**: クラス名を `OP_CLASS` と `OP_GETCONST` の両方から集めて
# いたため、`FOO = 7` の `FOO` がクラスとして登録されていました (PLC と同じ)。
class TestI8080Constants < Minitest::Test
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

  def run_ruby(source, max_steps: 2_000_000)
    rb = Tempfile.new(["const", ".rb"])
    rb.write(source)
    rb.close
    mrb = rb.path.sub(/\.rb$/, ".mrb")
    begin
      assert system(@mrbc, "-o", mrb, rb.path, out: File::NULL, err: File::NULL),
             "mrbc に失敗しました"
      gen = FaRuby::I8080BytecodeHex.new(File.binread(mrb))
      combined = Tempfile.new(["const", ".hex"])
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

  # **レジスタ番号に寄りかからないため**、整数の入っている値を集めます
  def int_values(board)
    (1...Layout::MAX_REGS).filter_map do |i|
      board.reg_value(i) if board.reg_type(i) == TT_INTEGER
    end
  end

  def assert_holds(source, value)
    result, board = run_ruby(source)
    assert_equal :finished, result
    assert_equal 0, board.vm_error_code
    assert_includes int_values(board), value
    board
  end

  def test_定数は作った値を返す
    assert_holds("FOO = 7\nx = FOO\n", 7)
  end

  # **これが直した不具合そのものです。** 以前はクラス番号が返っていました
  def test_定数はクラス番号を返さない
    board = assert_holds("A = 11\nB = 22\nx = A\ny = B\n", 11)
    assert_includes int_values(board), 22
  end

  def test_クラス変数は読み書きできる
    assert_holds(<<~RUBY, 7)
      class C
        def up
          @@n = 7
          @@n
        end
      end
      x = C.new.up
    RUBY
  end

  def test_クラス変数はオブジェクトをまたいで共有される
    assert_holds(<<~RUBY, 2)
      class C
        def inc
          @@n = (@@n || 0) + 1
        end
      end
      C.new.inc
      x = C.new.inc
    RUBY
  end

  def test_クラスが違えば別のクラス変数
    board = assert_holds(<<~RUBY, 1)
      class C
        def s
          @@n = 1
          @@n
        end
      end
      class D
        def s
          @@n = 2
          @@n
        end
      end
      x = C.new.s
      y = D.new.s
    RUBY
    assert_includes int_values(board), 2
  end

  # クラス名が定数に食われていないこと (逆方向の回帰)
  def test_クラス名はクラスのまま使える
    assert_holds(<<~RUBY, 5)
      class C
        def v
          5
        end
      end
      x = C.new.v
    RUBY
  end
end
