# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"

# mrbc を使った end-to-end テスト
# mrbc がインストールされていない場合はスキップされます
class TestEndToEnd < Minitest::Test

# テストは既定レイアウト (faruby_default.yml) を使う。
# 利用者の faruby.yml に影響されないようにするため。
def layout
  FaRuby::MemoryLayout.default
end
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

  # OP_LOADI のオペランドは符号なし (0-255)。負値は OP_LOADINEG が受け持つ。
  # 符号付きとして扱っていたころは 128 以上が負になり、`while i < 200` が
  # 一度も回らなかった。境界をまたぐ値を実際にコンパイルして確認する。
  def test_literals_across_the_signed_byte_boundary
    [127, 128, 200, 255, 256].each do |n|
      result = compile_and_run("a = #{n}\n")
      assert_equal n, result[:locals]["a"], "リテラル #{n}"
    end
  end

  def test_negative_literals_across_the_byte_boundary
    [-1, -127, -128, -200, -255, -256].each do |n|
      result = compile_and_run("a = #{n}\n")
      assert_equal n, result[:locals]["a"], "リテラル #{n}"
    end
  end

  # ループの上限が 127 を超えても回ること
  def test_loop_bound_above_the_signed_byte_boundary
    source = <<~RUBY
      i = 0
      while i < 200
        i = i + 1
      end
    RUBY
    result = compile_and_run(source)
    assert_equal 200, result[:locals]["i"]
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

  # F サフィックスは実数として扱われる。整数を代入すると実数に変換される
  def test_device_suffix_float_is_mapped
    rb_file = Tempfile.new(["test", ".rb"], "C:/tmp")
    rb_file.write("$DM460F = 1.5\n")
    rb_file.close
    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")

    begin
      assert system(@mrbc, "-o", mrb_path, rb_file.path)
      irep = FaRuby::MrbParser.new(File.binread(mrb_path)).parse.irep
      codegen = FaRuby::PlcCodegen.new(irep)

      assert_equal FaRuby::VmConstants::ACCESS_F, codegen.device_mappings[0][:access_type]
      # 実数リテラルは IEEE754 単精度でプールに載る
      image = codegen.fixed_image
      layout = codegen.layout
      bits = image[layout.pool_addr(0)] | (image[layout.pool_addr(0) + 1] << 16)
      assert_equal FaRuby::VmConstants::TT_FLOAT, image[layout.pool_type_addr(0)]
      assert_in_delta 1.5, [bits].pack("V").unpack1("e"), 1e-6
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
    end
  end

  # 汎用グローバル変数は 4 ワードのスロットに順番に割り当てられ、
  # デバイステーブルにはスロット先頭のアドレスが入る
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
      sim.em.read_s32(layout.general_global_addr(0)),
      sim.em.read_s32(layout.general_global_addr(1)),
    ]
    assert_equal [11, 22], slot_values.sort

    # 型タグも書かれる。整数を入れたので TT_INTEGER
    assert_equal FaRuby::VmConstants::TT_INTEGER,
                 sim.em.read_u16(layout.general_global_slot_addr(0))
    assert_equal FaRuby::VmConstants::TT_INTEGER,
                 sim.em.read_u16(layout.general_global_slot_addr(1))
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
    assert_equal 99, sim.em.read_s32(layout.general_global_addr(0))
  end

  # === 汎用グローバル変数はどの型でも持てる ===
  #
  # 値スロットをそのまま持つので、型タグごと写る。デバイスと違って幅が無い

  def test_a_general_global_keeps_a_float
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = 2.5
      $DM0 = 0
      if $g == 2.5
        $DM0 = 1
      end
    RUBY

    assert_equal 1, sim.devices[1].read_u16(0), "実数が切り捨てられている"
  end

  # 以前は 0 が入り、整数 0 は Ruby では真なので条件が通っていた
  def test_a_general_global_keeps_false_falsy
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = false
      $DM0 = 0
      if $g
        $DM0 = 1
      end
    RUBY

    assert_equal 0, sim.devices[1].read_u16(0), "false が真になっている"
  end

  def test_a_general_global_keeps_nil_falsy
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = nil
      $DM0 = 0
      if $g
        $DM0 = 1
      end
    RUBY

    assert_equal 0, sim.devices[1].read_u16(0), "nil が真になっている"
  end

  def test_a_general_global_keeps_an_array
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = [1, 2, 3]
      $DM0 = $g.length
    RUBY

    assert_equal 3, sim.devices[1].read_u16(0)
  end

  def test_a_general_global_keeps_a_hash
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = { 1 => 2 }
      $DM0 = $g[1]
    RUBY

    assert_equal 2, sim.devices[1].read_u16(0)
  end

  def test_a_general_global_keeps_a_string
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = "abc"
      $DM100 = $g
    RUBY

    dm = sim.devices[1]

    assert_equal [0x6162, 0x6300], [dm.read_u16(100), dm.read_u16(101)]
  end

  # 入るのはスロット番号だけ。プールは増えない
  def test_a_general_global_does_not_take_a_pool_slot
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [1, 2]
      $g = a
      $DM0 = $g.length
    RUBY

    assert_equal 2, sim.devices[1].read_u16(0)
    assert_equal 1, sim.em.read_u16(layout.array_sp_addr), "配列 1 つぶんだけ使う"
  end

  # === 同じ変数に違う型を入れ直す ===
  #
  # スロットごと上書きするので前の値は残らない。**ハッシュとデバイス参照は
  # 値ワードを 2 つ使う**ため、そこから整数へ戻すときに上のワードが
  # 消えることを確かめておく

  def test_a_general_global_can_change_type
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = 2.5
      $g = "abc"
      $g = 7
      $DM0 = $g
    RUBY

    assert_equal 7, sim.devices[1].read_u16(0)
  end

  # ハッシュは +1 に鍵、+2 に値の配列を置く。整数は 32 ビットで書くので両方消える
  def test_a_general_global_leaves_no_upper_word_behind
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = { 1 => 2 }
      $g = 9
      $DM0 = $g
    RUBY

    assert_equal 9, sim.devices[1].read_u16(0)
  end

  # 逆向き。整数の後にハッシュを入れても 2 ワードとも書かれる
  def test_a_general_global_takes_a_hash_after_an_integer
    sim = compile_and_run(<<~RUBY)[:sim]
      $g = 1
      $g = { 5 => 6 }
      $DM0 = $g[5]
    RUBY

    assert_equal 6, sim.devices[1].read_u16(0)
  end

  # デバイス族への参照も 2 ワード使う
  def test_a_general_global_keeps_a_device_family
    sim = compile_and_run(<<~RUBY)[:sim]
      $DM50 = 3
      $g = $DM
      $DM0 = $g[50]
    RUBY

    assert_equal 3, sim.devices[1].read_u16(0)
  end

  # === 配列をデバイスへ写す ===
  #
  # 刻みは幅で決まる。ビットデバイスは 1 ワードが 16 ビットにあたる。
  # 個別ビット (幅なし) には書けない

  # 止まることを確かめる用。compile_and_run は完走を前提にしている
  def run_until_it_stops(source)
    rb_file = Tempfile.new(["stop", ".rb"], "C:/tmp")
    rb_file.write(source)
    rb_file.close
    mrb_path = rb_file.path.sub(/.rb$/, ".mrb")
    assert system(@mrbc, "-o", mrb_path, rb_file.path), "mrbc に失敗"

    parser = FaRuby::MrbParser.new(File.binread(mrb_path)).parse
    sim = FaRuby::KvVmSimulator.new
    sim.load_irep_and_run(parser.irep)
    sim
  ensure
    [rb_file&.path, mrb_path].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  def test_an_array_writes_consecutive_words
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [11, 22, 33]
      $DM100 = a
    RUBY

    assert_equal [11, 22, 33], (0..2).map { |i| sim.devices[1].read_u16(100 + i) }
  end

  # .L は 2 ワードずつ進む
  def test_a_wide_array_steps_by_two_words
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [1, 2, 3]
      $DM100L = a
    RUBY

    assert_equal [1, 2, 3], (0..2).map { |i| sim.devices[1].read_s32(100 + i * 2) }
  end

  def test_an_array_of_floats
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [1.5, 2.5]
      $DM100F = a
    RUBY

    bits = (0..1).map { |i| sim.devices[1].read_u32(100 + i * 2) }

    assert_equal [1.5, 2.5], bits.map { |b| [b].pack("L").unpack1("f") }
  end

  # 添字を付けた形も同じ
  def test_an_indexed_array_write
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [7, 8]
      i = 0
      $DML[100 + i] = a
    RUBY

    assert_equal [7, 8], (0..1).map { |i| sim.devices[1].read_s32(100 + i * 2) }
  end

  # ビットデバイスは 1 ワードが 16 ビット。$MRL なら 32 ビットずつ進む。
  # 書いたものを faRuby 自身で読み戻して確かめる
  def test_an_array_to_a_bit_device_with_a_width
    sim = compile_and_run(<<~RUBY)[:sim]
      a = [5, 6]
      i = 0
      $MRL[64 + i] = a
      $DM100L = $MRL[64]
      $DM102L = $MRL[96]
    RUBY

    assert_equal [5, 6], [sim.devices[1].read_s32(100), sim.devices[1].read_s32(102)]
  end

  # 個別ビットには書けない。1 要素が何ビットか決まらない
  def test_an_array_to_a_plain_bit_device_stops_the_vm
    sim = run_until_it_stops(<<~RUBY)
      a = [1, 0]
      i = 0
      $MR[64 + i] = a
    RUBY

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # 数値でない要素があると止まる。入れ子の書き出し方は決めていない
  def test_an_array_with_a_string_stops_the_vm
    sim = run_until_it_stops(<<~RUBY)
      a = [1, "x"]
      $DM100 = a
    RUBY

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # ハッシュは鍵の並べ方が決まらない
  def test_a_hash_to_a_device_stops_the_vm
    sim = run_until_it_stops(<<~RUBY)
      h = { 1 => 2 }
      $DM100 = h
    RUBY

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # 空の配列は何も書かない
  def test_an_empty_array_writes_nothing
    sim = compile_and_run(<<~RUBY)[:sim]
      $DM100 = 99
      a = []
      $DM100 = a
    RUBY

    assert_equal 99, sim.devices[1].read_u16(100)
  end

  # === デバイスから配列へ ($DML[100, 3]) ===
  #
  # 引数 2 個の `[]` はメソッド呼び出しで、OP_GETIDX とは別経路。
  # Ruby の a[i, n] に合わせて、個数が負なら nil、0 なら空の配列

  def test_a_slice_reads_consecutive_words
    sim = compile_and_run(<<~RUBY)[:sim]
      $DM100 = [11, 22, 33]
      a = $DM[100, 3]
      $DM200 = a.length
      $DM201 = a[0]
      $DM202 = a[2]
    RUBY

    assert_equal [3, 11, 33], (0..2).map { |i| sim.devices[1].read_u16(200 + i) }
  end

  # .L は 2 ワードずつ進む。書く向きと同じ規則
  def test_a_wide_slice_steps_by_two_words
    sim = compile_and_run(<<~RUBY)[:sim]
      $DM100L = [7, 8]
      a = $DML[100, 2]
      $DM200 = a[0]
      $DM201 = a[1]
    RUBY

    assert_equal [7, 8], (0..1).map { |i| sim.devices[1].read_u16(200 + i) }
  end

  def test_a_slice_of_zero_is_an_empty_array
    sim = compile_and_run(<<~RUBY)[:sim]
      a = $DM[100, 0]
      $DM200 = a.length
    RUBY

    assert_equal 0, sim.devices[1].read_u16(200)
  end

  # Ruby の a[i, -1] は nil
  def test_a_negative_count_is_nil
    sim = compile_and_run(<<~RUBY)[:sim]
      a = $DM[100, -1]
      $DM200 = 0
      if a == nil
        $DM200 = 1
      end
    RUBY

    assert_equal 1, sim.devices[1].read_u16(200)
  end

  # 1 スロットの容量を超える個数
  def test_a_slice_past_the_capacity_stops_the_vm
    sim = run_until_it_stops("a = $DM[100, #{FaRuby::MemoryLayout.default.max_array_len + 1}]\n")

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # ビットデバイスは 1 ワードが 16 ビット
  def test_a_slice_from_a_bit_device_with_a_width
    sim = compile_and_run(<<~RUBY)[:sim]
      $MRL[64] = [5, 6]
      a = $MRL[64, 2]
      $DM200 = a[0]
      $DM201 = a[1]
    RUBY

    assert_equal [5, 6], (0..1).map { |i| sim.devices[1].read_u16(200 + i) }
  end

  # 個別ビットは 1 要素が何ビットか決まらない
  def test_a_slice_from_a_plain_bit_device_stops_the_vm
    sim = run_until_it_stops("a = $MR[64, 2]\n")

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # 配列の部分取り出し (Ruby の a[1, 2]) は入れていない
  def test_a_slice_of_an_array_stops_the_vm
    sim = run_until_it_stops(<<~RUBY)
      b = [1, 2, 3]
      c = b[1, 2]
    RUBY

    assert_equal FaRuby::VmConstants::VM_ERROR, sim.status
  end

  # === 添字によるデバイスアクセス ===
  #
  # $DM100 はコンパイル時にアドレスが確定するため、実行時に計算した
  # アドレスを読み書きできない。裸の $DM に添字を付けて解決する。

  def test_device_index_write_and_read_in_a_loop
    source = <<~RUBY
      i = 0
      while i < 5
        $DM[600 + i] = i * 10
        i = i + 1
      end
      sum = 0
      i = 0
      while i < 5
        sum = sum + $DM[600 + i]
        i = i + 1
      end
    RUBY
    result = compile_and_run(source)
    dm = result[:sim].devices[FaRuby::VmConstants::DEVICE_TYPE_DM]

    assert_equal [0, 10, 20, 30, 40], (0..4).map { |i| dm.read_s16(600 + i) }
    assert_equal 100, result[:locals]["sum"]
  end

  def test_device_index_honours_the_width_suffix
    result = compile_and_run("$DML[612] = 70000\n")
    dm = result[:sim].devices[FaRuby::VmConstants::DEVICE_TYPE_DM]

    assert_equal 70_000, dm.read_s32(612)
  end

  # 範囲外は黙って別の場所を読み書きしてしまうため、VM を止める
  def test_device_index_out_of_range_stops_the_vm
    [-1, 70_000].each do |index|
      sim = run_expecting_error("$DM[#{index}] = 1\n")
      assert_equal FaRuby::VmConstants::VM_ERROR, sim.status, "添字 #{index}"
    end
  end

  # 幅サフィックスを付けると、そのビットから連続したビット列を整数として扱う
  # (実機で確認済み。1ビット刻みでチャンネル境界に揃っていなくてよい)
  def test_bit_device_with_a_width_reads_a_bit_field
    source = <<~RUBY
      $MR[64] = true
      $MR[65] = true
      $MR[66] = true
      a = $MRL[64]
    RUBY
    result = compile_and_run(source)

    assert_equal 7, result[:locals]["a"], "下位3ビットが立つ"
  end

  def test_bit_device_with_a_width_writes_a_bit_field
    result = compile_and_run("$MRU[80] = 6\n")
    mr = result[:sim].devices[FaRuby::VmConstants::DEVICE_TYPE_MR]

    assert_equal [0, 1, 1, 0], (80..83).map { |n| mr.read_u16(n) }, "6 = 0b110"
  end

  # チャンネル境界に揃っていない位置から読める
  def test_bit_field_can_start_anywhere
    source = <<~RUBY
      $MR[17] = true
      $MR[20] = true
      a = $MRU[17]
    RUBY
    result = compile_and_run(source)

    assert_equal 9, result[:locals]["a"], "bit0 と bit3"
  end

  # ビットデバイスも同じ経路。添字はデバイス番号 (MR400 は 64)
  def test_device_index_works_for_bit_devices
    source = <<~RUBY
      $MR[64] = true
      $MR[65] = false
      $MR[66] = true
    RUBY
    result = compile_and_run(source)
    mr = result[:sim].devices[FaRuby::VmConstants::DEVICE_TYPE_MR]

    assert_equal [1, 0, 1], [64, 65, 66].map { |n| mr.read_u16(n) }
  end

  private

  # エラー停止することを期待して実行する (compile_and_run は完了を要求する)
  def run_expecting_error(source)
    rb_file = Tempfile.new(["test", ".rb"], "C:/tmp")
    rb_file.write(source)
    rb_file.close
    mrb_path = rb_file.path.sub(/\.rb$/, ".mrb")

    begin
      assert system(@mrbc, "-o", mrb_path, rb_file.path)
      irep = FaRuby::MrbParser.new(File.binread(mrb_path)).parse.irep
      sim = FaRuby::KvVmSimulator.new
      sim.load_irep_and_run(irep)
      sim
    ensure
      rb_file.unlink
      File.delete(mrb_path) if File.exist?(mrb_path)
    end
  end

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
      parser = FaRuby::MrbParser.new(data).parse
      sim = FaRuby::KvVmSimulator.new
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
