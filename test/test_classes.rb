# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# クラス
#
# **足りなかったのは 3 命令だけでした** — `OP_CLASS` / `OP_EXEC` /
# `OP_GETCONST`。クラス本体はふつうの irep で、中身は `OP_TCLASS` /
# `OP_METHOD` / `OP_DEF` という `def` と同じ並びです。
#
# 作り直しになったのはメソッド表で、1 本 (名前 → irep) から **クラス × 名前**
# になりました。呼ぶ側はレシーバのクラスを知らないので、探索は実行時です。
#
# `new` も入りました (段階 2)。**インスタンス変数はまだクラスごとでは
# なく共有です** (段階 3)。設計は [クラスの計画](../doc/classes.md)。
class TestClasses < Minitest::Test
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

  # --- 道具 ---

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
    sim.load_irep_and_run(irep, max_steps: 50_000)
    [sim, FaRuby::PlcCodegen.new(irep)]
  end

  def error_of(sim) = sim.em.read_u16(layout.error_addr)

  def dm0(sim) = sim.devices[DEVICE_TYPE_DM].read_s16(0)

  # クラス番号の行に入っている (名前 ID => irep) の組
  def row(sim, class_number)
    (0...layout.max_methods).each_with_object({}) do |id, acc|
      irep = sim.em.read_u16(layout.method_table_addr(class_number, id))
      acc[id] = irep unless irep == METHOD_UNDEFINED
    end
  end

  # --- クラスの定義 ---

  def test_a_class_definition_runs_to_the_end
    sim, = run_source(<<~RUBY)
      class Counter
        def up
          1
        end
      end
      $DM0 = 7
    RUBY

    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 7, dm0(sim)
  end

  # **メソッドはそのクラスの行に入ります。** main (0 行目) ではありません
  def test_a_method_lands_in_its_own_class_row
    sim, codegen = run_source(<<~RUBY)
      class Counter
        def up
          1
        end
      end
    RUBY

    number = codegen.class_numbers.fetch("Counter")

    assert_equal 1, number, "最初のクラスは 1 番 (0 番は main)"
    assert_equal 1, row(sim, number).size, "Counter の行に 1 つ入っていない"
    assert_empty row(sim, CLASS_MAIN), "main の行に入ってしまっている"
  end

  # トップレベルの `def` は main の行
  def test_a_top_level_def_lands_in_the_main_row
    sim, = run_source(<<~RUBY)
      def top_level
        9
      end
      $DM0 = top_level
    RUBY

    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 9, dm0(sim)
    assert_equal 1, row(sim, CLASS_MAIN).size
  end

  # **これが作り直しの理由です。** 1 本の表では同じ名前で衝突しました
  def test_two_classes_may_define_the_same_name
    sim, codegen = run_source(<<~RUBY)
      class A
        def value
          1
        end
      end
      class B
        def value
          2
        end
      end
    RUBY

    a = row(sim, codegen.class_numbers.fetch("A"))
    b = row(sim, codegen.class_numbers.fetch("B"))

    assert_equal 1, a.size
    assert_equal 1, b.size
    assert_equal a.keys, b.keys, "名前の ID は同じ"
    refute_equal a.values, b.values, "行が違うので別の irep を指す"
  end

  # クラスとトップレベルが混ざっても行が分かれる
  def test_classes_and_the_top_level_keep_separate_rows
    sim, codegen = run_source(<<~RUBY)
      class Counter
        def up
          1
        end
        def down
          2
        end
      end
      def top_level
        9
      end
      $DM0 = top_level
    RUBY

    assert_equal 9, dm0(sim)
    assert_equal 2, row(sim, codegen.class_numbers.fetch("Counter")).size
    assert_equal 1, row(sim, CLASS_MAIN).size
  end

  # --- 型タグ ---

  # `OP_TCLASS` は self を返す。クラス本体ではそのクラス
  def test_the_target_class_inside_a_body_is_the_class
    source = FaRuby::KvsGenerator.new.source
    branch = source[/定義先は self。クラス本体では.*?\n.*?\n.*?\n/m]

    refute_nil branch, "OP_TCLASS が self を写していない"
  end

  # クラスは実行時に作らない。番号をシンボル表から読むだけ
  def test_a_class_is_not_built_at_run_time
    source = FaRuby::KvsGenerator.new.source

    assert_includes source, "#{TT_CLASS}", "TT_CLASS を置いていない"
    assert_includes source, "クラス番号"
  end

  # --- 上限 ---

  # **0 行目は main なので、クラスは max_classes - 1 まで**
  def test_too_many_classes_stops_before_transfer
    names = (1..layout.max_classes).map { |i| "class C#{i}\nend\n" }.join
    irep = compile(names)

    error = assert_raises(FaRuby::CodegenError) do
      FaRuby::PlcCodegen.new(irep).validate!
    end

    assert_includes error.message, "クラスの数"
  end

  def test_one_less_than_the_limit_passes
    names = (1...layout.max_classes).map { |i| "class C#{i}\nend\n" }.join

    FaRuby::PlcCodegen.new(compile(names)).validate!
  end

  # --- new ---

  # **`new` はただの `OP_SEND`** です。レシーバがクラスの組み込みメソッド
  def test_new_returns_an_object_and_its_method_runs
    sim, = run_source(<<~SRC)
      class Counter
        def up
          7
        end
      end
      c = Counter.new
      $DM0 = c.up
    SRC

    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 7, dm0(sim)
  end

  # **`initialize` があれば呼びます。** 引数の数は `OP_ENTER` が見ます
  def test_initialize_runs_with_its_arguments
    sim, = run_source(<<~SRC)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
      end
      c = Counter.new(5)
      $DM0 = c.value
    SRC

    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 5, dm0(sim), "initialize が走っていない"
  end

  # **戻り値で上書きされないこと。** initialize の戻り値ではなくオブジェクト
  def test_new_returns_the_object_not_initializes_value
    sim, = run_source(<<~SRC)
      class Counter
        def initialize
          99
        end
        def up
          7
        end
      end
      $DM0 = Counter.new.up
    SRC

    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 7, dm0(sim), "initialize の戻り値がオブジェクトを上書きした"
  end

  # オブジェクトはプールのスロットを 1 つ使う
  def test_an_object_takes_one_pool_slot
    sim, = run_source(<<~SRC)
      class Counter
        def up
          1
        end
      end
      a = Counter.new
      b = Counter.new
      $DM0 = a.up + b.up
    SRC

    assert_equal 2, dm0(sim)
    assert_equal 2, sim.em.read_u16(layout.array_sp_addr), "スロットを 2 つ使っていない"
  end

  # **レシーバがクラスでなければ `new` は呼べません**
  def test_new_on_a_non_class_stops
    sim, = run_source("$DM0 = 1.new\n")

    assert_equal VM_ERROR, sim.status
    assert_equal 4, error_of(sim), "レシーバの型エラーで止まらない"
  end
end
