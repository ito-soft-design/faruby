# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"
require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# 文字列
#
# 実体は配列プールのスロットに置き、見出しの後ろに 1 ワード 2 バイトで
# 詰めます。**先の文字が上位バイト**で、KV-5000 の文字列デバイスと同じ並びです。
# バイト列は変換しないため、デバイスへの書き込みはワード単位の写しで済みます。
#
# mrbc を通すため、mrbc が見つからない環境では実行時テストを飛ばします。
class TestStrings < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def mrbc_path
    @mrbc_path ||= begin
      FaRuby::Config.new(nil).mrbc_path
    rescue StandardError
      nil
    end
  end

  def run_source(source)
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    dir = File.expand_path("../tmp", __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    src = File.join(dir, "strings_test.rb")
    mrb = File.join(dir, "strings_test.mrb")
    File.binwrite(src, source)
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL), "mrbc に失敗"

    parser = FaRuby::MrbParser.new(File.binread(mrb))
    parser.parse
    sim = FaRuby::KvVmSimulator.new(layout: layout)
    sim.load_irep_and_run(parser.irep, max_steps: 100_000)
    sim
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  def status(sim) = sim.em.read_u16(layout.status_addr)
  def error(sim)  = sim.em.read_u16(layout.error_addr)

  # DM を 16 進のワード列で読む
  def words(sim, base, count)
    dm = sim.devices[DEVICE_TYPE_DM]
    (0...count).map { |i| dm.read_u16(base + i) }
  end

  def assert_finished(sim)
    assert_equal VM_FINISHED, status(sim), "実行が完了しなかった (error=#{error(sim)})"
  end

  # === OP_STRING ===

  def test_a_literal_lands_in_a_pool_slot
    sim = run_source(%(s = "hello"\n))

    assert_finished sim
    assert_equal 1, sim.em.read_u16(layout.array_sp_addr), "スロットを 1 つ使う"
    assert_equal "hello", string_bytes(sim, 0)
  end

  # Ruby の文字列は変更できるので、同じリテラルを 2 回書けば別のもの
  def test_the_same_literal_twice_takes_two_slots
    sim = run_source(%(s = "hi"\nt = "hi"\n))

    assert_equal 2, sim.em.read_u16(layout.array_sp_addr)
    assert_equal "hi", string_bytes(sim, 0)
    assert_equal "hi", string_bytes(sim, 1)
  end

  # 1 ワードに 2 バイト、先の文字が上位。KV-5000 と同じ並び
  def test_bytes_pack_two_to_a_word_with_the_first_byte_high
    sim = run_source(%(s = "ABCDE "\n))
    slot = layout.string_word_addr(0, 0)

    assert_equal 0x4142, sim.em.read_u16(slot)
    assert_equal 0x4344, sim.em.read_u16(slot + 1)
    assert_equal 0x4520, sim.em.read_u16(slot + 2)
  end

  # バイト列は変換しない。ソースのバイトがそのまま入る
  def test_bytes_are_not_converted
    sim = run_source(%(s = "あ"\n))

    assert_equal "\xE3\x81\x82".b, string_bytes(sim, 0)
  end

  def test_an_empty_literal
    sim = run_source(%(s = ""\n))

    assert_finished sim
    assert_equal "", string_bytes(sim, 0)
  end

  # 返さないスロットを使うため、ループの中のリテラルは使い切る
  def test_literals_in_a_loop_exhaust_the_pool
    sim = run_source(<<~RUBY)
      #{layout.max_arrays + 1}.times do |i|
        s = "x"
      end
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal 10, error(sim)
  end

  # === FARUBY_STR_FILL ===

  def test_the_setting_constant_reaches_vm_state
    sim = run_source("FARUBY_STR_FILL = 0x20\n")

    assert_finished sim
    assert_equal 0x20, sim.em.read_u16(layout.str_fill_addr)
  end

  def test_the_fill_defaults_to_zero
    sim = run_source(%(s = "a"\n))

    assert_equal 0, sim.em.read_u16(layout.str_fill_addr)
  end

  # 接頭辞で始まらない定数は利用者のもの。何もしない
  def test_an_ordinary_constant_is_ignored
    sim = run_source("MY_LIMIT = 5\n")

    assert_finished sim
    assert_equal 0, sim.em.read_u16(layout.str_fill_addr)
  end

  # === 終端付きの書き込み ===

  # 書き方は増えない。値が文字列かどうかは実行時のタグで分かる
  def test_a_terminated_write_adds_a_zero
    sim = run_source(%($DM800 = "abc"\n))

    assert_finished sim
    assert_equal [0x6162, 0x6300], words(sim, 800, 2)
  end

  # 偶数バイトなら終端に 1 ワード余分に要る
  def test_an_even_length_string_takes_another_word_for_the_terminator
    sim = run_source(%($DM800 = "abcd"\n))

    assert_equal [0x6162, 0x6364, 0x0000], words(sim, 800, 3)
  end

  def test_an_empty_string_writes_only_the_terminator
    sim = run_source(%($DM800 = ""\n))

    assert_equal [0x0000], words(sim, 800, 1)
  end

  # === 固定長の書き込み ===

  def test_a_short_string_is_padded_with_the_fill
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "abc"
    RUBY

    assert_finished sim
    assert_equal [0x6162, 0x6320, 0x2020], words(sim, 800, 3)
  end

  # 埋めないと前に書いた長い文字列の尻尾が残る
  def test_the_fill_wipes_what_a_longer_write_left
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "abcdef"
      $DM800T6 = "xy"
    RUBY

    assert_equal [0x7879, 0x2020, 0x2020], words(sim, 800, 3)
  end

  # ちょうどなら終端を書かない。書くと次の桁にはみ出す
  def test_an_exact_fit_writes_no_terminator
    sim = run_source(%($DM800T6 = "ABCDEF"\n))

    assert_equal [0x4142, 0x4344, 0x4546, 0x0000], words(sim, 800, 4)
  end

  # 表示器の桁は決まっている。止めるより書く
  def test_a_long_string_is_truncated
    sim = run_source(%($DM800T4 = "abcdefgh"\n))

    assert_finished sim
    assert_equal [0x6162, 0x6364], words(sim, 800, 2)
  end

  # 桁数が奇数なら最後のワードの下位バイトは桁の外。ワード単位でしか書けない
  def test_an_odd_width_leaves_zero_outside_the_field
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T5 = "ab"
    RUBY

    assert_equal [0x6162, 0x2020, 0x2000], words(sim, 800, 3)
  end

  def test_the_fill_defaults_to_zero_when_the_program_does_not_set_it
    sim = run_source(%($DM800T6 = "abc"\n))

    assert_equal [0x6162, 0x6300, 0x0000], words(sim, 800, 3)
  end

  # === 弾くもの ===

  # 文字列の桁 (T) に文字列以外を書こうとした
  def test_a_number_to_a_string_field_stops_the_vm
    sim = run_source("$DM800T6 = 5\n")

    assert_equal VM_ERROR, status(sim)
  end

  # ビットデバイスは転送前に止まる。表示器から読めないため
  def test_a_string_field_on_a_bit_device_stops_the_build
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.parse_device_name("MR100T6") }
  end

  # === 生成コード ===

  # Z6 はデバイスのベースアドレス。写している途中で壊すと書き先がずれる
  def test_the_string_write_does_not_clobber_the_base_address
    source = FaRuby::KvsGenerator.new.source
    branch = source[/ELSE IF EM0:Z2 = #{TT_STRING} THEN\n(.*?)\n                ELSE\n/m, 1]
    refute_nil branch, "文字列の書き込みが見つからない"

    refute_match(/^\s+Z6 = /, branch, "ベースアドレスを書き換えている")
  end

  # FOR の中で BREAK すると FOR を抜けるだけで命令ループから出られない。
  # エラーを書いてもそのまま走り続け、最後に STOP が status を上書きする。
  # デバイス種別の検査は写しの FOR に入る前に済ませる
  def test_the_string_write_does_not_break_inside_the_loop
    source = FaRuby::KvsGenerator.new.source
    branch = source[/ELSE IF EM0:Z2 = #{TT_STRING} THEN\n(.*?)\n                ELSE\n/m, 1]
    refute_nil branch, "文字列の書き込みが見つからない"

    inside = branch[/FOR Z\d+ = 0 TO.*?\n\s*NEXT/m]
    refute_nil inside, "写しの FOR が見つからない"
    refute_includes inside, "BREAK", "FOR の中で BREAK すると FOR を抜けるだけになる"
  end

  def test_string_opcodes_are_implemented
    codes = FaRuby::OpcodeTable.codes

    assert_includes codes, 0x51, "OP_STRING が未実装"
    assert_includes codes, 0x1E, "OP_SETCONST が未実装"
    refute_includes codes, 0x1D, "OP_GETCONST は実装しない (設定を読む必要が無い)"
  end

  private

  # スロットのバイト列
  def string_bytes(sim, slot)
    length = sim.em.read_u16(layout.array_slot_addr(slot) + Layout::ARRAY_LENGTH)
    bytes = +""
    ((length + 1) / 2).times do |i|
      word = sim.em.read_u16(layout.string_word_addr(slot, i))
      bytes << (word >> 8).chr << (word & 0xFF).chr
    end
    bytes.byteslice(0, length)
  end
end
