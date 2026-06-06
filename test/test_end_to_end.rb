# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"

# mrbc を使った end-to-end テスト
# mrbc がインストールされていない場合はスキップされます
class TestEndToEnd < Minitest::Test
  MRBC_PATHS = [
    "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
    File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
  ].freeze

  def setup
    @mrbc = find_mrbc
    skip "mrbc not found" unless @mrbc
  end

  def test_01_literal
    result = compile_and_run("a = 3\n")
    assert_equal 3, result[:locals]["a"]
  end

  def test_02_add
    result = compile_and_run("a = 1\nb = 2\nc = a + b\n")
    assert_equal 1, result[:locals]["a"]
    assert_equal 2, result[:locals]["b"]
    assert_equal 3, result[:locals]["c"]
  end

  def test_03_arith
    result = compile_and_run("a = 1 + 2\nb = a * 3\n")
    assert_equal 3, result[:locals]["a"]
    assert_equal 9, result[:locals]["b"]
  end

  def test_04_all_ops
    result = compile_and_run("x = 100\ny = x - 37\nz = y / 3\n")
    assert_equal 100, result[:locals]["x"]
    assert_equal 63,  result[:locals]["y"]
    assert_equal 21,  result[:locals]["z"]
  end

  def test_negative_number
    result = compile_and_run("a = -5\nb = a + 10\n")
    assert_equal(-5, result[:locals]["a"])
    assert_equal 5,  result[:locals]["b"]
  end

  def test_larger_number
    result = compile_and_run("a = 1000\nb = a * 2\n")
    assert_equal 1000, result[:locals]["a"]
    assert_equal 2000, result[:locals]["b"]
  end

  def test_if_true_branch
    source = <<~RUBY
      a = 5
      b = 0
      if a > 3
        b = 1
      else
        b = 2
      end
    RUBY
    result = compile_and_run(source)
    assert_equal 5, result[:locals]["a"]
    assert_equal 1, result[:locals]["b"]
  end

  def test_if_false_branch
    source = <<~RUBY
      a = 1
      b = 0
      if a > 3
        b = 1
      else
        b = 2
      end
    RUBY
    result = compile_and_run(source)
    assert_equal 1, result[:locals]["a"]
    assert_equal 2, result[:locals]["b"]
  end

  def test_while_loop
    source = <<~RUBY
      a = 0
      i = 0
      while i < 5
        a = a + i
        i = i + 1
      end
    RUBY
    result = compile_and_run(source)
    assert_equal 10, result[:locals]["a"]  # 0+1+2+3+4 = 10
    assert_equal 5, result[:locals]["i"]
  end

  # --- マイルストーン3: グローバル変数テスト ---

  def test_global_var_write
    source = <<~RUBY
      $foo = 42
    RUBY
    result = compile_and_run(source)
    assert_equal 42, result[:sim].global_value("$foo")
  end

  def test_global_var_read_write
    source = <<~RUBY
      $foo = 10
      a = $foo + 5
    RUBY
    result = compile_and_run(source)
    assert_equal 10, result[:sim].global_value("$foo")
    assert_equal 15, result[:locals]["a"]
  end

  def test_global_var_in_loop
    source = <<~RUBY
      $count = 0
      i = 0
      while i < 5
        $count = $count + 1
        i = i + 1
      end
    RUBY
    result = compile_and_run(source)
    assert_equal 5, result[:sim].global_value("$count")
    assert_equal 5, result[:locals]["i"]
  end

  def test_global_var_dm_device
    source = <<~RUBY
      $DM100 = 42
    RUBY
    result = compile_and_run(source)
    # DM100 はデバイスタイプ1 (DM), アドレス100 にマッピングされる
    sim = result[:sim]
    assert_equal 42, sim.global_value("$DM100")
    # DM デバイスメモリ (devices[1]) のアドレス100に書き込まれていることを確認
    assert_equal 42, sim.devices[1].read_s32(100)
  end

  # --- 実デバイスアクセステスト ---

  def test_device_io_multi_device
    source = <<~RUBY
      $DM100 = 42
      $MR10 = 1
      $MR200 = $DM100 + $MR10
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    # DM デバイス (type=1, ワード): 32ビット値
    assert_equal 42, sim.devices[1].read_s32(100)
    # MR デバイス (type=4, ビット): 0 or 1
    assert_equal 1, sim.devices[4].read_u16(10)
    # MR デバイス (type=4, ビット): 42+1=43 → 非0 → 1
    # MR200 は HEXDEC → Z offset = 32
    assert_equal 1, sim.devices[4].read_u16(32)
  end

  def test_device_io_zf
    source = <<~RUBY
      $ZF500 = 999
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    assert_equal 999, sim.global_value("$ZF500")
    assert_equal 999, sim.devices[2].read_s32(500)
  end

  def test_device_io_loop_dm
    source = <<~RUBY
      $DM0 = 0
      i = 0
      while i < 10
        $DM0 = $DM0 + i
        i = i + 1
      end
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    # 0+1+2+...+9 = 45
    assert_equal 45, sim.devices[1].read_s32(0)
  end

  def test_device_io_cross_device_copy
    source = <<~RUBY
      $DM50 = 123
      $ZF10 = $DM50
      $MR0 = $ZF10
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    assert_equal 123, sim.devices[1].read_s32(50)   # DM50 (ワード)
    assert_equal 123, sim.devices[2].read_s32(10)   # ZF10 (ワード)
    assert_equal 1, sim.devices[4].read_u16(0)      # MR0 (ビット): 123→非0→1
  end

  def test_device_io_negative_value
    source = <<~RUBY
      $DM200 = -100
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    assert_equal(-100, sim.devices[1].read_s32(200))
  end

  private

  def find_mrbc
    MRBC_PATHS.each do |path|
      return path if File.exist?(path)
    end
    nil
  end

  # Ruby ソースをコンパイル・パース・シミュレーション実行し、ローカル変数の値を返す
  def compile_and_run(source)
    # 一時ファイルに書き出し
    rb_file = Tempfile.new(["test", ".rb"], "C:/tmp")
    rb_file.write(source)
    rb_file.close

    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")

    begin
      # mrbc でコンパイル
      success = system(@mrbc, "-o", mrb_path, rb_file.path)
      raise "mrbc compilation failed" unless success

      # パースして実行
      data = File.binread(mrb_path)
      parser = MrubycOnPlc::MrbParser.new(data).parse
      sim = MrubycOnPlc::KvVmSimulator.new
      sim.load_irep_and_run(parser.irep)

      assert_equal 2, sim.status, "VM should finish (status=2)"

      # ローカル変数名を推測 (R[1]から順に source 内の代入文の左辺)
      var_names = source.scan(/^\s*(\w+)\s*=/).flatten.uniq
      locals = {}
      var_names.each_with_index do |name, i|
        locals[name] = sim.reg(i + 1)  # R[0]=self, R[1]=first local
      end

      { locals: locals, sim: sim, irep: parser.irep }
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
    end
  end
end
