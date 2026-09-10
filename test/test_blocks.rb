# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# ブロックと上位の変数
#
# ブロックはメソッドと違い、外側のローカル変数を読み書きします。そのため
# 本体の irep だけでなく **定義元のフレーム**も覚えておき、`OP_GETUPVAR` の
# 段数ぶん鎖を辿ります。
#
# 反復 (times / upto) はまだ無いため、ここではバイトコードを直接置いて
# 命令の単位で確かめます。
class TestBlocks < Minitest::Test
  include FaRuby::VmConstants
  include FaRuby::OpcodeTable

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def setup
    @sim = FaRuby::KvVmSimulator.new(layout: layout)
  end

  BLOCK     = 0x57
  GETUPVAR  = 0x21
  SETUPVAR  = 0x22
  METHOD    = 0x58
  LOADI_0   = 0x06
  STOP      = 0x69

  def run_bytecode(bytes, nregs: 8, ireps: 2)
    em = @sim.em
    em.write_u16(layout.pc_addr, 0)
    em.write_u16(layout.status_addr, VM_RUNNING)
    em.write_u16(layout.bytecode_len_addr, bytes.size)
    em.write_u16(layout.nregs_addr, nregs)
    em.write_u16(layout.num_ireps_addr, ireps)
    # 実行中の irep (0) の最初の子は 1
    @sim.fixed.write_u16(layout.irep_table_addr(0) + Layout::IREP_FIRST_CHILD, 1)
    bytes.each_with_index { |b, i| @sim.fixed.write_u16(layout.bytecode_addr(i), b) }
    @sim.run
  end

  def tag_of(index)   = @sim.em.read_u16(layout.reg_type_addr(index))
  def value_of(index) = @sim.em.read_s32(layout.reg_addr(index))
  def word_of(index, offset) = @sim.em.read_u16(layout.reg_addr(index) + offset)
  def status = @sim.em.read_u16(layout.status_addr)
  def error  = @sim.em.read_u16(layout.error_addr)

  # フレームを 1 段積む (呼び出しの途中を模す)
  def push_frame(own_base:, outer:)
    sp = @sim.em.read_u16(layout.frame_sp_addr)
    addr = layout.frame_addr(sp)
    @sim.em.write_u16(addr + Layout::FRAME_OWN_BASE, own_base)
    @sim.em.write_u16(addr + Layout::FRAME_OUTER, outer)
    @sim.em.write_u16(layout.frame_sp_addr, sp + 1)
    sp
  end

  # レジスタ窓は呼び出しごとにずれるため、窓の先頭を指定して読み書きする
  def slot_addr(base_offset, index) = layout.origin + base_offset + index * SLOT_WORDS

  def set_reg(index, base_offset, tag, value)
    addr = slot_addr(base_offset, index)
    @sim.em.write_u16(addr + SLOT_TYPE_OFFSET, tag)
    @sim.em.write_s32(addr + SLOT_VALUE_OFFSET, value)
  end

  def get_reg(index, base_offset)
    addr = slot_addr(base_offset, index)
    [@sim.em.read_u16(addr + SLOT_TYPE_OFFSET), @sim.em.read_s32(addr + SLOT_VALUE_OFFSET)]
  end

  # === フレームの形 ===

  # 反復の現在値と上限は 32 ビット。負の値や 65535 超も扱えるようにするため
  def test_frame_holds_iteration_state_as_32_bit
    assert_equal 2, Layout::FRAME_LIMIT - Layout::FRAME_INDEX
    assert_operator Layout::FRAME_LIMIT + 2, :<=, Layout::FRAME_WORDS
  end

  # 「フレームが無い」印は実在するフレーム番号と重ならないこと
  def test_frame_none_is_out_of_range
    assert_operator Layout::FRAME_NONE, :>=, layout.max_frames
  end

  # doc/architecture.md の「呼び出しフレームとレジスタ窓」に載せた数値。
  # 配置を変えると図が古くなるため、ここで気づけるようにしておく。
  def test_the_frame_diagram_in_the_docs_matches_the_layout
    assert_equal 56, layout.offset_of(layout.reg_file_base), "レジスタ領域の先頭"
    assert_equal 376, layout.offset_of(layout.frame_stack_base), "呼び出しスタックの先頭"
    assert_equal 10, Layout::FRAME_WORDS
    assert_equal 16, layout.max_frames
    assert_equal 20_376, layout.frame_addr(0)
    assert_equal 20_386, layout.frame_addr(1)
    assert_equal 20_526, layout.frame_addr(layout.max_frames - 1)
    # a=1 の呼び出しで窓が +56 から +60 へ進む
    assert_equal 60, layout.offset_of(layout.reg_file_base) + 1 * SLOT_WORDS
  end

  # === OP_BLOCK ===

  # ブロックは本体の irep と定義元のフレームの両方を持つ。
  # irep だけではどのフレームの変数を見ればよいか分からない。
  def test_block_captures_the_defining_frame
    run_bytecode([BLOCK, 0x01, 0x00, STOP])

    assert_equal TT_PROC, tag_of(1)
    assert_equal 1, word_of(1, 0), "本体の irep"
    assert_equal Layout::FRAME_NONE, word_of(1, 1), "トップレベルで定義した"
  end

  # メソッドは外側を見ないので定義元を持たない
  def test_method_has_no_defining_frame
    run_bytecode([METHOD, 0x01, 0x00, STOP])

    assert_equal TT_PROC, tag_of(1)
    assert_equal Layout::FRAME_NONE, word_of(1, 1)
  end

  def test_block_rejects_a_missing_child
    run_bytecode([BLOCK, 0x01, 0x05, STOP], ireps: 2)

    assert_equal VM_ERROR, status
    assert_equal IREP_INDEX_ERROR, error
  end

  # === OP_GETUPVAR / OP_SETUPVAR ===

  # 段数 0 は 1 つ外側。定義元のフレームのレジスタ窓を見る
  def test_getupvar_reads_the_immediately_enclosing_frame
    outer_base = layout.offset_of(layout.reg_file_base)
    inner_base = outer_base + 8 * SLOT_WORDS
    set_reg(1, outer_base, TT_INTEGER, 42)

    push_frame(own_base: inner_base, outer: Layout::FRAME_NONE)
    @sim.em.write_u16(layout.reg_base_addr, inner_base)

    run_bytecode([GETUPVAR, 0x02, 0x01, 0x00, STOP])

    assert_equal VM_FINISHED, status, "error=#{error}"
    assert_equal [TT_INTEGER, 42], get_reg(2, inner_base)
  end

  def test_setupvar_writes_the_immediately_enclosing_frame
    outer_base = layout.offset_of(layout.reg_file_base)
    inner_base = outer_base + 8 * SLOT_WORDS

    push_frame(own_base: inner_base, outer: Layout::FRAME_NONE)
    @sim.em.write_u16(layout.reg_base_addr, inner_base)
    set_reg(2, inner_base, TT_INTEGER, 77)

    run_bytecode([SETUPVAR, 0x02, 0x01, 0x00, STOP])

    assert_equal VM_FINISHED, status, "error=#{error}"
    assert_equal [TT_INTEGER, 77], get_reg(1, outer_base)
  end

  # 入れ子のブロックは 1 段より上を見る。よくある形なので落とせない
  #
  #   2.times { 2.times { s = s + 1 } }   →  OP_GETUPVAR [3, 1, 1]
  def test_getupvar_walks_the_chain_for_nested_blocks
    top_base = layout.offset_of(layout.reg_file_base)
    middle_base = top_base + 8 * SLOT_WORDS
    inner_base  = top_base + 16 * SLOT_WORDS
    set_reg(1, top_base, TT_INTEGER, 5)

    middle = push_frame(own_base: middle_base, outer: Layout::FRAME_NONE)
    push_frame(own_base: inner_base, outer: middle)
    @sim.em.write_u16(layout.reg_base_addr, inner_base)

    run_bytecode([GETUPVAR, 0x02, 0x01, 0x01, STOP])

    assert_equal VM_FINISHED, status, "error=#{error}"
    assert_equal [TT_INTEGER, 5], get_reg(2, inner_base), "2 段外側のトップレベルを見る"
  end

  # トップレベルには外側が無い
  def test_getupvar_at_the_top_level_stops_the_vm
    run_bytecode([GETUPVAR, 0x02, 0x01, 0x00, STOP])

    assert_equal VM_ERROR, status
    assert_equal UPVAR_ERROR, error
  end

  # 鎖より深い段数を指定したらエラー。黙って別の場所を読ませない
  def test_getupvar_beyond_the_chain_stops_the_vm
    base = layout.offset_of(layout.reg_file_base)
    push_frame(own_base: base + 8 * SLOT_WORDS, outer: Layout::FRAME_NONE)
    @sim.em.write_u16(layout.reg_base_addr, base + 8 * SLOT_WORDS)

    run_bytecode([GETUPVAR, 0x02, 0x01, 0x03, STOP])

    assert_equal VM_ERROR, status
    assert_equal UPVAR_ERROR, error
  end

  # === 反復 (Ruby から動かす) ===

  def mrbc_path
    @mrbc_path ||= begin
      require_relative "../tools/config"
      FaRuby::Config.new(nil).mrbc_path
    rescue StandardError
      nil
    end
  end

  def run_source(source)
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    dir = FaRuby::TempDir.path
    src = File.join(dir, "blocks_test.rb")
    mrb = File.join(dir, "blocks_test.mrb")
    File.binwrite(src, source)
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL), "mrbc に失敗"

    parser = FaRuby::MrbParser.new(File.binread(mrb))
    parser.parse
    sim = FaRuby::KvVmSimulator.new(layout: layout)
    sim.load_irep_and_run(parser.irep, max_steps: 200_000)
    sim
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  def dm0(sim)
    value = sim.devices[DEVICE_TYPE_DM].read_u16(0)
    value > 32_767 ? value - 65_536 : value
  end

  def assert_result(expected, source, message = nil)
    sim = run_source(source)
    err = sim.em.read_u16(layout.error_addr)
    assert_equal VM_FINISHED, sim.status, "#{message} 実行が完了しなかった (error=#{err})"
    assert_equal expected, dm0(sim), message
  end

  def test_times_passes_the_index
    assert_result 3, <<~RUBY
      sum = 0
      3.times do |i|
        sum = sum + i
      end
      $DM0 = sum
    RUBY
  end

  # 引数を書かないブロックにも times は 1 個渡す。
  # メソッドと同じ検査をすると引数の数が合わずに止まる
  def test_a_block_without_parameters
    assert_result 4, <<~RUBY
      n = 0
      4.times do
        n = n + 1
      end
      $DM0 = n
    RUBY
  end

  def test_zero_times_never_enters_the_block
    assert_result 0, <<~RUBY
      n = 0
      0.times do
        n = n + 1
      end
      $DM0 = n
    RUBY
  end

  def test_upto
    assert_result 12, <<~RUBY
      sum = 0
      3.upto(5) do |i|
        sum = sum + i
      end
      $DM0 = sum
    RUBY
  end

  def test_upto_with_a_smaller_limit_never_enters_the_block
    assert_result 0, <<~RUBY
      n = 0
      5.upto(3) do
        n = n + 1
      end
      $DM0 = n
    RUBY
  end

  # 内側のブロックから外側の外側を読む。段数 1 の OP_GETUPVAR になる
  def test_nested_blocks_reach_the_outermost_variable
    assert_result 6, <<~RUBY
      s = 0
      3.times do |i|
        2.times do |j|
          s = s + i
        end
      end
      $DM0 = s
    RUBY
  end

  def test_break_stops_the_iteration
    assert_result 3, <<~RUBY
      n = 0
      10.times do |i|
        break if i == 3
        n = n + 1
      end
      $DM0 = n
    RUBY
  end

  # メソッドのフレームの上に反復のフレームが積まれる
  def test_a_block_inside_a_method
    assert_result 6, <<~RUBY
      def total(n)
        s = 0
        n.times do |i|
          s = s + i
        end
        s
      end
      $DM0 = total(4)
    RUBY
  end

  def test_calling_a_method_from_inside_a_block
    assert_result 6, <<~RUBY
      def twice(v)
        v * 2
      end
      s = 0
      3.times do |i|
        s = s + twice(i)
      end
      $DM0 = s
    RUBY
  end

  # 反復が終わったら呼び出し元の続きに戻る
  def test_execution_continues_after_the_block
    assert_result 15, <<~RUBY
      s = 0
      3.times do |i|
        s = s + i
      end
      s = s + 12
      $DM0 = s
    RUBY
  end

  # ブロックを取るメソッドはブロック無しでは呼べない
  def test_times_without_a_block_stops_the_vm
    sim = run_source("$DM0 = 3.times\n")

    assert_equal VM_ERROR, sim.status
    assert_equal UNKNOWN_METHOD_ERROR, sim.em.read_u16(layout.error_addr)
  end

  # === ハッシュの each ===
  #
  # ブロックに引数を 2 つ渡す唯一の経路。反復フレームの種別で分ける

  def test_hash_each_passes_the_key_and_the_value
    assert_result 33, <<~RUBY
      h = { 1 => 10, 2 => 20 }
      sum = 0
      h.each do |k, v|
        sum = sum + k + v
      end
      $DM0 = sum
    RUBY
  end

  # Ruby は [鍵, 値] の配列を渡すが、faRuby は鍵だけを渡す。
  # 配列を毎回作るとプールを食い潰すための意図的な差
  def test_a_hash_each_block_with_one_parameter_gets_the_key
    assert_result 3, <<~RUBY
      h = { 1 => 10, 2 => 20 }
      sum = 0
      h.each do |k|
        sum = sum + k
      end
      $DM0 = sum
    RUBY
  end

  def test_a_hash_each_block_without_parameters
    assert_result 2, <<~RUBY
      h = { 1 => 10, 2 => 20 }
      n = 0
      h.each do
        n = n + 1
      end
      $DM0 = n
    RUBY
  end

  # 1 回も回らないときはレシーバがそのまま呼び出しの値になる
  def test_an_empty_hash_never_enters_the_block
    assert_result 7, <<~RUBY
      h = {}
      n = 7
      h.each do |k, v|
        n = 0
      end
      $DM0 = n
    RUBY
  end

  def test_break_out_of_a_hash_each
    assert_result 1, <<~RUBY
      h = { 1 => 10, 2 => 20 }
      sum = 0
      h.each do |k, v|
        sum = sum + k
        break
      end
      $DM0 = sum
    RUBY
  end

  # 反復の途中でユーザー定義メソッドを呼ぶと call_argc がその引数の数で
  # 上書きされ、次の回の OP_ENTER がブロックの引数を消していた。
  # 引数の数は渡す値と一緒に毎回書き直す
  def test_calling_a_method_inside_a_block_keeps_the_block_argument
    assert_result 6, <<~RUBY
      def zero
        0
      end

      a = [1, 2, 3]
      sum = 0
      a.each do |v|
        zero
        sum = sum + v
      end
      $DM0 = sum
    RUBY
  end

  def test_calling_a_method_inside_a_hash_each_keeps_both_arguments
    assert_result 33, <<~RUBY
      def zero
        0
      end

      h = { 1 => 10, 2 => 20 }
      sum = 0
      h.each do |k, v|
        zero
        sum = sum + k + v
      end
      $DM0 = sum
    RUBY
  end

  def test_calling_a_method_inside_times_keeps_the_index
    assert_result 3, <<~RUBY
      def one(x)
        x
      end

      sum = 0
      3.times do |i|
        one(9)
        sum = sum + i
      end
      $DM0 = sum
    RUBY
  end

  # === 生成コード ===

  # FOR の中で BREAK すると FOR を抜けるだけで命令ループから出られない。
  # 鎖を辿る途中のエラーは印を立てて FOR の外で判定する。
  #
  # **字下げの深さは見ない。** 振り分けの組み方を変えると深さが動くため。
  def test_generated_upvar_walk_does_not_break_inside_the_loop
    source = FaRuby::KvsGenerator.new.source
    body = source[/' OP_GETUPVAR .*?\n(.*?)\n\s*' OP_\w+ /m, 1]
    refute_nil body, "OP_GETUPVAR の本体が見つからない"

    inside = body[/FOR Z\d+ = 1 TO.*?\n\s*NEXT/m]
    refute_nil inside, "鎖を辿る FOR が見つからない"
    refute_includes inside, "BREAK", "FOR の中で BREAK すると FOR を抜けるだけになる"
  end

  def test_block_opcodes_are_implemented
    codes = FaRuby::OpcodeTable.codes
    { 0x57 => :OP_BLOCK, 0x21 => :OP_GETUPVAR, 0x22 => :OP_SETUPVAR }.each do |code, name|
      assert_includes codes, code, "#{name} が未実装"
    end
  end
end
