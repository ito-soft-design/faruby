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
    assert_equal 42, sim.devices[1].read_s16(100)
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
    # DM デバイス (type=1, ワード): 既定は16ビット符号付き
    assert_equal 42, sim.devices[1].read_s16(100)
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
    assert_equal 999, sim.devices[2].read_s16(500)
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
    assert_equal 45, sim.devices[1].read_s16(0)
  end

  def test_device_io_cross_device_copy
    source = <<~RUBY
      $DM50 = 123
      $ZF10 = $DM50
      $MR0 = $ZF10
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    assert_equal 123, sim.devices[1].read_s16(50)   # DM50 (ワード)
    assert_equal 123, sim.devices[2].read_s16(10)   # ZF10 (ワード)
    assert_equal 1, sim.devices[4].read_u16(0)      # MR0 (ビット): 123→非0→1
  end

  def test_device_io_negative_value
    source = <<~RUBY
      $DM200 = -100
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]
    assert_equal(-100, sim.devices[1].read_s16(200))
  end

  # --- アクセス幅サフィックス ---

  # 既定 (サフィックス無し) は 1 ワードしか占有しない
  def test_device_default_width_is_one_word
    source = <<~RUBY
      $DM400 = 1
      $DM401 = 2
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    # 隣接アドレスが独立して使える (32ビット既定なら衝突していた)
    assert_equal 1, sim.devices[1].read_s16(400)
    assert_equal 2, sim.devices[1].read_s16(401)
    assert_equal 1, sim.global_value("$DM400")
    assert_equal 2, sim.global_value("$DM401")
  end

  # L サフィックス: 32ビット符号付き (2ワード)
  def test_device_suffix_long
    source = <<~RUBY
      $DM410L = 100000
      $DM420L = -100000
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    assert_equal 100000, sim.global_value("$DM410L")
    assert_equal(-100000, sim.global_value("$DM420L"))
    assert_equal 100000, sim.devices[1].read_s32(410)
    assert_equal(-100000, sim.devices[1].read_s32(420))
  end

  # U サフィックス: 16ビット符号なし
  def test_device_suffix_unsigned
    source = <<~RUBY
      $DM430U = 60000
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    assert_equal 60000, sim.global_value("$DM430U")
    assert_equal 60000, sim.devices[1].read_u16(430)
    # 同じビット列を符号付きで読むと負になる
    assert_equal(-5536, sim.devices[1].read_s16(430))
  end

  # D サフィックス: 32ビット符号なし
  def test_device_suffix_unsigned_long
    source = <<~RUBY
      $DM440D = 100000
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    assert_equal 100000, sim.global_value("$DM440D")
    assert_equal 100000, sim.devices[1].read_u32(440)
  end

  # 幅の違う変数が同じデバイスを別々に見られる
  def test_device_suffix_mixed_widths
    source = <<~RUBY
      $DM450L = 100000
      $lo = $DM450
      $hi = $DM451
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    # 100000 = 0x000186A0 → 下位 0x86A0, 上位 0x0001
    assert_equal 100000, sim.global_value("$DM450L")
    assert_equal 0x0001, sim.global_value("$hi")
    assert_equal(-31072, sim.global_value("$lo"))  # 0x86A0 (34464) を符号付き16ビットで読んだ値
  end

  # F サフィックスは未実装なのでコンパイル時にエラーになる
  def test_device_suffix_float_is_rejected
    rb_file = Tempfile.new(["test", ".rb"], "C:/tmp")
    rb_file.write("$DM460F = 1\n")
    rb_file.close
    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")

    begin
      assert system(@mrbc, "-o", mrb_path, rb_file.path)
      irep = MrubycOnPlc::MrbParser.new(File.binread(mrb_path)).parse.irep
      err = assert_raises(MrubycOnPlc::CodegenError) do
        MrubycOnPlc::PlcCodegen.new(irep).memory_image
      end
      assert_match(/実数/, err.message)
      assert_match(/\$DM460F/, err.message)
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
    end
  end

  # 汎用グローバル変数は 4 ワードのスロットに順番に割り当てられ、
  # デバイステーブルには値ワード (スロット先頭+1) のアドレスが入る
  def test_general_global_slot_layout
    source = <<~RUBY
      $foo = 11
      $bar = 22
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    assert_equal 11, sim.global_value("$foo")
    assert_equal 22, sim.global_value("$bar")

    # スロット 0 と 1 に重なりなく格納されている (シンボル順は問わない)
    slot_values = [
      sim.em.read_s32(MrubycOnPlc::MemoryMap.general_global_addr(0)),
      sim.em.read_s32(MrubycOnPlc::MemoryMap.general_global_addr(1)),
    ]
    assert_equal [11, 22], slot_values.sort

    # 型タグ領域は未使用のまま
    assert_equal MrubycOnPlc::MemoryMap::TT_EMPTY,
                 sim.em.read_u16(MrubycOnPlc::MemoryMap.general_global_slot_addr(0))
    assert_equal MrubycOnPlc::MemoryMap::TT_EMPTY,
                 sim.em.read_u16(MrubycOnPlc::MemoryMap.general_global_slot_addr(1))
  end

  # デバイス名付きグローバルが混在しても汎用グローバルの採番は詰めて行われる
  def test_general_global_numbering_skips_device_symbols
    source = <<~RUBY
      $DM100 = 1
      $foo = 99
    RUBY
    result = compile_and_run(source)
    sim = result[:sim]

    assert_equal 99, sim.global_value("$foo")
    # $DM100 は汎用領域を消費しないので $foo はスロット 0
    assert_equal 99, sim.em.read_s32(MrubycOnPlc::MemoryMap.general_global_addr(0))
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
