# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../tools/features"
require_relative "../tools/kvs_generator"
require_relative "../tools/config"
require_relative "../tools/mrb_parser"
require_relative "../tools/plc_codegen"

# 機種ごとに載せる機能
#
# **プログラム容量が足りない機種のための仕組みです。** MELSEC Q はクラスを
# 入れた時点でプログラムメモリに収まらなくなりました。
#
# **切り口は値の型です。命令ではありません。** 命令だけを外しても実測で
# 2〜4% しか減らず、かさばっているのは `OP_SEND` や `OP_GETIDX` のような
# 共有する命令の中の型ごとの枝でした (tools/features.rb)。
class TestFeatures < Minitest::Test
  include FaRuby::VmConstants

  Features = FaRuby::Features

  MRBC_PATHS = [
    "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
    File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
  ].freeze

  # --- 設定 ---

  def test_everything_is_on_by_default
    assert Features.all.all?, "既定は全機能"
    assert_empty Features.all.disabled
  end

  def test_an_unknown_feature_is_rejected
    error = assert_raises(FaRuby::FeatureError) { Features.new(strings: false, colours: true) }

    assert_includes error.message, "colours"
  end

  # **共有しているメソッドは全員が外れたときだけ落ちます**
  def test_a_shared_method_survives_while_one_type_remains
    only_strings_off = Features.new(strings: false)

    assert only_strings_off.method?(:length), "配列とハッシュが length を使う"
    refute_includes only_strings_off.removed_methods, :length
  end

  def test_a_shared_method_is_dropped_when_every_type_is_off
    none = Features.new(arrays: false, hashes: false, strings: false)

    refute none.method?(:length)
    assert_includes none.removed_methods, :length
    assert_includes none.removed_methods, :push
    assert_includes none.removed_methods, :keys
  end

  # 整数のメソッドは残る
  def test_number_methods_are_never_dropped
    none = Features.new(arrays: false, hashes: false, strings: false)

    %i[abs to_i floor round % times upto loop].each do |name|
      assert none.method?(name), "#{name} が落ちている"
    end
  end

  # **クラスが残ればプールは要ります** (`new` が使う)
  def test_the_pool_is_still_needed_for_objects
    assert Features.new(arrays: false, hashes: false, strings: false).heap?
    refute Features.new(arrays: false, hashes: false, strings: false, classes: false).heap?
  end

  # --- 機種の設定 ---

  def test_the_q_has_the_three_types_off
    q = FaRuby::Config.defaults.for_model("Q")

    assert_equal %i[arrays hashes strings], q.features.disabled
    assert q.features.classes?, "クラスは残す"
  end

  def test_the_other_models_keep_everything
    %w[KV-5000 KV-X500 iQ-R].each do |model|
      assert FaRuby::Config.defaults.for_model(model).features.all?, "#{model} は全機能"
    end
  end

  # --- 生成物 ---

  def generate(model, features)
    layout = FaRuby::Config.defaults.for_model(model).layout
    FaRuby::KvsGenerator.new(layout: layout, dialect: FaRuby::Dialect.for(model),
                             features: features).source
  end

  # **これが仕組みの目的です。** 外すと目に見えて減る
  def test_dropping_the_three_types_shrinks_the_q_by_a_third
    full = generate("Q", Features.all).lines.size
    cut  = generate("Q", Features.new(arrays: false, hashes: false, strings: false)).lines.size

    assert_operator cut, :<, full * 0.75, "3 割減っていない (#{full} → #{cut})"
  end

  # 外した型のメソッドの振り分けが消える
  def test_the_dropped_methods_leave_no_branch
    source = generate("Q", Features.new(arrays: false, hashes: false, strings: false))

    %w[push keys values key?].each do |name|
      refute_includes source, "(* #{name} *)", "#{name} の枝が残っている"
    end
    assert_includes source, "(* abs *)", "整数のメソッドは残る"
  end

  # 分岐の対応が崩れていないこと (ST は END_IF の数で分かる)
  def test_the_generated_branches_stay_balanced
    source = generate("Q", Features.new(arrays: false, hashes: false, strings: false))
    opens = source.scan(/\bIF .*\bTHEN\b/).size
    closes = source.scan(/END_IF/).size

    assert_equal opens, closes, "IF と END_IF の数が合わない"
  end

  # --- コンパイル時の検査 ---

  def compile(source)
    mrbc = MRBC_PATHS.find { |p| File.executable?(p) }
    skip "mrbc not found" unless mrbc

    Dir.mktmpdir do |dir|
      rb = File.join(dir, "f.rb")
      mrb = File.join(dir, "f.mrb")
      File.write(rb, source, encoding: "utf-8")
      assert system(mrbc, "-o", mrb, rb, out: File::NULL, err: File::NULL)
      return FaRuby::MrbParser.new(File.binread(mrb)).parse.irep
    end
  end

  def validate_for_q(source)
    q = FaRuby::Config.defaults.for_model("Q")
    FaRuby::PlcCodegen.new(compile(source), layout: q.layout, features: q.features,
                           device_syntax: FaRuby::DeviceSyntax.melsec).validate!
  end

  # **実機で「未知のオペコード」にはしません。** 転送の前に止めます
  def test_using_a_string_stops_before_transfer
    error = assert_raises(FaRuby::FeatureError) { validate_for_q(%($DM100 = "abc")) }

    assert_includes error.message, "文字列"
  end

  def test_using_an_array_stops_before_transfer
    error = assert_raises(FaRuby::FeatureError) { validate_for_q("$DM100 = [1, 2].length\n") }

    assert_includes error.message, "配列"
  end

  def test_using_a_hash_stops_before_transfer
    error = assert_raises(FaRuby::FeatureError) { validate_for_q("h = { a: 1 }\n$DM100 = h[:a]\n") }

    assert_includes error.message, "ハッシュ"
  end

  # クラスは残しているので通る
  def test_a_class_passes_on_the_q
    validate_for_q(<<~RUBY)
      class Counter
        def initialize(n)
          @n = n
        end
        def value
          @n
        end
      end
      $DM100 = Counter.new(5).value
    RUBY
  end

  # 整数だけのプログラムは当然通る
  def test_an_integer_program_passes_on_the_q
    validate_for_q("$DM100 = 1 + 2 * 3\n")
  end

  # **全機能の機種では何も弾きません**
  def test_nothing_is_rejected_when_every_feature_is_on
    kv = FaRuby::Config.defaults.for_model("KV-5000")
    irep = compile(%($DM100 = [1, 2].length))

    FaRuby::PlcCodegen.new(irep, layout: kv.layout, features: kv.features).validate!
  end
end
