# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# 定数とクラス変数
#
# **置き場は汎用グローバルの値スロットです。** どちらも `$foo` と同じ場所に
# 入るので、VM に新しい領域は要りませんでした。足したのは前処理 2 つ
# (`OP_GETCV` / `OP_SETCV` が `OP_GETGV` / `OP_SETGV` の枝へ落ちる) と、
# `OP_GETCONST` / `OP_SETCONST` の種別による振り分けだけです。
#
# **直した不具合**: クラス名を `OP_CLASS` と `OP_GETCONST` の両方から集めて
# いたため、`FOO = 7` の `FOO` がクラスとして登録され、`$DM0 = FOO` が 7 では
# なく**クラス番号の 1 を書いて完了していました** (エラーも出ません)。
# クラス名は `OP_CLASS` だけから集めます。
class TestConstants < Minitest::Test
  include FaRuby::VmConstants

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
      rb = File.join(dir, "c.rb")
      mrb = File.join(dir, "c.mrb")
      File.write(rb, source, encoding: "utf-8")
      assert system(@mrbc, "-o", mrb, rb, out: File::NULL, err: File::NULL),
             "mrbc に失敗しました"
      return FaRuby::MrbParser.new(File.binread(mrb)).parse.irep
    end
  end

  def run_source(source)
    irep = compile(source)
    sim = FaRuby::KvVmSimulator.new
    sim.load_irep_and_run(irep, max_steps: 200_000)
    sim
  end

  def dm(sim, index) = sim.devices[DEVICE_TYPE_DM].read_s16(index)
  def error_of(sim) = sim.em.read_u16(layout.error_addr)

  def assert_finished(sim)
    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 0, error_of(sim)
  end

  # --- 定数 ---

  def test_定数は作った値を返す
    sim = run_source("FOO = 7\n$DM0 = FOO\n")
    assert_finished sim
    assert_equal 7, dm(sim, 0)
  end

  # **これが直した不具合そのものです。** 以前は 1 (クラス番号) でした
  def test_定数はクラス番号を返さない
    sim = run_source("A = 11\nB = 22\nC = 33\n$DM0 = A\n$DM1 = B\n$DM2 = C\n")
    assert_finished sim
    assert_equal [11, 22, 33], [dm(sim, 0), dm(sim, 1), dm(sim, 2)]
  end

  def test_定数に文字列を入れられる
    sim = run_source("NAME = \"abc\"\n$DM0 = NAME.length\n")
    assert_finished sim
    assert_equal 3, dm(sim, 0)
  end

  def test_定数はメソッドの中から読める
    sim = run_source("LIMIT = 9\ndef f\n  LIMIT\nend\n$DM0 = f\n")
    assert_finished sim
    assert_equal 9, dm(sim, 0)
  end

  def test_クラスの中の定数はそのクラスのメソッドから読める
    sim = run_source(<<~RUBY)
      class C
        LIMIT = 7
        def l
          LIMIT
        end
      end
      $DM0 = C.new.l
    RUBY
    assert_finished sim
    assert_equal 7, dm(sim, 0)
  end

  # クラス名が定数に食われていないこと (逆方向の回帰)
  def test_クラス名はクラスのまま使える
    sim = run_source(<<~RUBY)
      class C
        def v
          5
        end
      end
      $DM0 = C.new.v
    RUBY
    assert_finished sim
    assert_equal 5, dm(sim, 0)
  end

  def test_設定定数は従来どおり_vm_状態へ行く
    sim = run_source("FARUBY_STR_FILL = 32\n$DM0 = 7\n")
    assert_finished sim
    assert_equal 32, sim.em.read_u16(layout.str_fill_addr)
  end

  # --- クラス変数 ---

  def test_クラス変数は読み書きできる
    sim = run_source(<<~RUBY)
      class C
        def up
          @@n = 7
          @@n
        end
      end
      $DM0 = C.new.up
    RUBY
    assert_finished sim
    assert_equal 7, dm(sim, 0)
  end

  # **オブジェクトをまたいで共有されること。** インスタンス変数との違いです
  def test_クラス変数はオブジェクトをまたいで共有される
    sim = run_source(<<~RUBY)
      class C
        def inc
          @@n = (@@n || 0) + 1
        end
      end
      C.new.inc
      $DM0 = C.new.inc
    RUBY
    assert_finished sim
    assert_equal 2, dm(sim, 0)
  end

  # **クラスごとに別の枠であること。** 名前だけで枠を取ると混ざります
  def test_クラスが違えば別のクラス変数
    sim = run_source(<<~RUBY)
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
      $DM0 = C.new.s
      $DM1 = D.new.s
    RUBY
    assert_finished sim
    assert_equal [1, 2], [dm(sim, 0), dm(sim, 1)]
  end

  def test_インスタンス変数とクラス変数は別物
    sim = run_source(<<~RUBY)
      class C
        def set
          @n = 1
          @@n = 2
        end
        def iv
          @n
        end
        def cv
          @@n
        end
      end
      c = C.new
      c.set
      $DM0 = c.iv
      $DM1 = c.cv
    RUBY
    assert_finished sim
    assert_equal [1, 2], [dm(sim, 0), dm(sim, 1)]
  end

  # --- 止めるもの ---

  def test_トップレベルのクラス変数はコンパイル時に止まる
    irep = compile("@@n = 1\n$DM0 = 1\n")
    e = assert_raises(FaRuby::CodegenError) do
      FaRuby::PlcCodegen.new(irep).memory_image
    end
    assert_match(/トップレベル/, e.message)
  end

  # **実行時の「未知のオペコード 31」では遅すぎます**
  def test_クラス付きの定数はコンパイル時に止まる
    irep = compile("class C\n  LIMIT = 7\nend\n$DM0 = C::LIMIT\n")
    e = assert_raises(FaRuby::CodegenError) do
      FaRuby::PlcCodegen.new(irep).memory_image
    end
    assert_match(/LIMIT/, e.message)
  end

  # --- 枠の取り方 ---

  # 定数とクラス変数が汎用グローバルの枠を取っていること
  def test_定数とクラス変数は汎用グローバルの枠を取る
    irep = compile(<<~RUBY)
      FOO = 1
      class C
        def s
          @@n = 2
        end
      end
      $DM0 = FOO
      C.new.s
    RUBY
    codegen = FaRuby::PlcCodegen.new(irep)
    codegen.memory_image
    kinds = codegen.device_mappings.each_with_object({}) do |e, acc|
      acc[e[:symbol]] = e[:kind]
    end

    assert_equal SYMBOL_KIND_GLOBAL, kinds["FOO"], "定数が汎用グローバルでない"
    assert_equal SYMBOL_KIND_GLOBAL, kinds["@@n"], "クラス変数が汎用グローバルでない"
    assert_equal SYMBOL_KIND_CLASS, kinds["C"], "クラス名がクラスでない"
  end

  # **同じ名前のクラス変数が別の枠に入ること。** アドレスで見ます
  def test_クラスごとに別のアドレスを取る
    irep = compile(<<~RUBY)
      class C
        def s
          @@n = 1
        end
      end
      class D
        def s
          @@n = 2
        end
      end
      C.new.s
      D.new.s
    RUBY
    codegen = FaRuby::PlcCodegen.new(irep)
    codegen.memory_image
    addrs = codegen.device_mappings.select { |e| e[:symbol] == "@@n" }
                   .map { |e| e[:z_offset] }.uniq

    assert_equal 2, addrs.size, "@@n が 1 つの枠を共有しています (#{addrs.inspect})"
  end
end
