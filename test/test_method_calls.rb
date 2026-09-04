# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"
require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# メソッドの定義と呼び出し
#
# 呼び出しフレームを積み、レジスタ窓をずらして子 irep へ移ります。
# 呼ばれた側の R[0] は呼んだ側の R[a] と同じ場所なので、戻り値のコピーは要りません。
#
# mrbc を通すため、mrbc が見つからない環境では実行時テストを飛ばします。
class TestMethodCalls < Minitest::Test
  include FaRuby::VmConstants
  include FaRuby::OpcodeTable

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def mrbc_path
    @mrbc_path ||= begin
      FaRuby::Config.new(nil).mrbc_path
    rescue StandardError
      nil
    end
  end

  # Ruby ソースを実行し、シミュレータを返す
  def run_source(source)
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    dir = File.expand_path("../tmp", __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    src = File.join(dir, "method_calls_test.rb")
    mrb = File.join(dir, "method_calls_test.mrb")
    File.binwrite(src, source)
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL),
           "mrbc に失敗しました"

    parser = FaRuby::MrbParser.new(File.binread(mrb))
    parser.parse
    sim = FaRuby::KvVmSimulator.new(layout: layout)
    sim.load_irep_and_run(parser.irep, max_steps: 100_000)
    sim
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  # $DM0 は 16 ビット符号付き
  def dm0(sim)
    value = sim.devices[DEVICE_TYPE_DM].read_u16(0)
    value > 32_767 ? value - 65_536 : value
  end

  def error_of(sim) = sim.em.read_u16(layout.error_addr)

  def assert_result(expected, source, message = nil)
    sim = run_source(source)
    assert_equal VM_FINISHED, sim.status,
                 "#{message} 実行が完了しませんでした (error=#{error_of(sim)})"
    assert_equal expected, dm0(sim), message
  end

  def assert_stops_with(code, source, message = nil)
    sim = run_source(source)
    assert_equal VM_ERROR, sim.status, message
    assert_equal code, error_of(sim), message
  end

  # === 呼び出し ===

  def test_call_without_arguments
    assert_result 7, <<~RUBY
      def seven
        7
      end
      $DM0 = seven
    RUBY
  end

  def test_call_with_arguments
    assert_result 5, <<~RUBY
      def add(a, b)
        a + b
      end
      $DM0 = add(2, 3)
    RUBY
  end

  # 呼び出しごとにレジスタ窓が戻らないと 2 回目が壊れる
  def test_calling_twice_in_one_expression
    assert_result 10, <<~RUBY
      def twice(v)
        v * 2
      end
      $DM0 = twice(2) + twice(3)
    RUBY
  end

  def test_nested_calls
    assert_result 12, <<~RUBY
      def twice(v)
        v * 2
      end
      def quad(v)
        twice(twice(v))
      end
      $DM0 = quad(3)
    RUBY
  end

  # 再帰はフレームとレジスタ窓の両方が積み上がる
  def test_recursion
    assert_result 120, <<~RUBY
      def fact(n)
        if n <= 1
          1
        else
          n * fact(n - 1)
        end
      end
      $DM0 = fact(5)
    RUBY
  end

  # メソッドの途中の return もフレームを戻す
  def test_early_return
    assert_result 0, <<~RUBY
      def clamp(v)
        return 0 if v < 0
        v * 2
      end
      $DM0 = clamp(-3)
    RUBY
  end

  def test_local_variables_inside_a_method
    assert_result 14, <<~RUBY
      def calc(v)
        t = v * 2
        u = t + 4
        u
      end
      $DM0 = calc(5)
    RUBY
  end

  # デバイスアクセスはシンボル表を引く。シンボル表は irep ごとに別なので、
  # 子 irep の中でも正しい位置を引けている必要がある
  def test_device_access_inside_a_method
    assert_result 99, <<~RUBY
      def store
        $DM0 = 99
      end
      store
    RUBY
  end

  # 同じ名前のグローバル変数は irep をまたいでも同じスロットを指す
  def test_general_globals_are_shared_across_ireps
    assert_result 8, <<~RUBY
      def bump
        $total = $total + 5
      end
      $total = 3
      bump
      $DM0 = $total
    RUBY
  end

  def test_builtin_methods_still_work_alongside_calls
    assert_result 3, <<~RUBY
      def neg(v)
        0 - v
      end
      a = neg(3)
      $DM0 = a.abs
    RUBY
  end

  # === エラー ===

  def test_calling_an_undefined_method_stops_the_vm
    assert_stops_with UNKNOWN_METHOD_ERROR, "$DM0 = nosuch\n"
  end

  def test_wrong_argument_count_stops_the_vm
    assert_stops_with ARGUMENT_ERROR, <<~RUBY
      def one(v)
        v
      end
      $DM0 = one(1, 2)
    RUBY
  end

  # PLC はメモリが固定なので、深さの上限を決めてエラーにするしかない
  def test_runaway_recursion_stops_the_vm
    assert_stops_with CALL_DEPTH_ERROR, <<~RUBY
      def deep(n)
        deep(n + 1)
      end
      $DM0 = deep(1)
    RUBY
  end

  # 省略可能引数・可変長・キーワードは未対応
  def test_optional_arguments_stop_the_vm
    assert_stops_with ARGUMENT_ERROR, <<~RUBY
      def opt(a, b = 1)
        a + b
      end
      $DM0 = opt(2)
    RUBY
  end

  # === ホスト側の解決 ===

  # シンボル表は irep ごとに別なので、名前を通し番号に解決しないと
  # どのエントリから呼んでも同じメソッドに行き着かない
  def test_method_names_resolve_to_ids_shared_across_ireps
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    sim = run_source(<<~RUBY)
      def fact(n)
        if n <= 1
          1
        else
          n * fact(n - 1)
        end
      end
      $DM0 = fact(3)
    RUBY
    assert_equal 6, dm0(sim)
  end

  # === 生成コード ===

  def test_generated_code_pushes_and_pops_frames
    source = FaRuby::KvsGenerator.new.source
    emitter = FaRuby::KvsEmitter.new(layout: layout)

    assert_includes source, "IF #{emitter.state(layout.frame_sp_addr)} >= #{layout.max_frames} THEN",
                    "呼び出しの深さの上限を見る"
    assert_includes source, "#{emitter.state(layout.reg_base_addr)} = " \
                            "#{emitter.state(layout.reg_base_addr)} + ",
                    "レジスタ窓をずらす"
  end

  # 実装済みのオペコードに揃っていること
  def test_call_opcodes_are_implemented
    codes = FaRuby::OpcodeTable.codes
    { 0x2D => :OP_SSEND, 0x34 => :OP_ENTER, 0x38 => :OP_RETURN,
      0x58 => :OP_METHOD, 0x5F => :OP_DEF, 0x63 => :OP_TCLASS }.each do |code, name|
      assert_includes codes, code, "#{name} が未実装"
    end
  end
end
