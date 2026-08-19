# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/memory_map"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"

# KV スクリプト生成器のテスト
class TestKvsGenerator < Minitest::Test
  include MrubycOnPlc::MemoryMap

  VM_CORE_PATH = File.expand_path("../plc/keyence/vm_core.kvs", __dir__)

  def setup
    @source = MrubycOnPlc::KvsGenerator.new.source
  end

  # コード行 (コメント・空行を除く)
  def code_lines(text)
    text.lines.map(&:rstrip).reject { |l| l.strip.empty? || l.strip.start_with?("'") }
  end

  # === コミット済みファイルとの一致 ===

  # 生成物は手で編集しない。編集された場合はここで検出する。
  # 直し方: tools/opcode_table.rb を修正して `rake vm_core` を実行する。
  def test_committed_file_matches_generated_output
    committed = File.binread(VM_CORE_PATH)
    assert_equal @source.b, committed,
                 "plc/keyence/vm_core.kvs が生成結果と一致しません。" \
                 "手で編集した場合は tools/opcode_table.rb に反映して `rake vm_core` を実行してください。"
  end

  def test_generate_returns_named_files
    files = MrubycOnPlc::KvsGenerator.new.generate
    assert_equal ["vm_core.kvs"], files.keys
    refute_empty files["vm_core.kvs"]
  end

  # === 型サフィックスの位置 (過去に91箇所で誤っていた) ===

  # 正: EM0.L:Z1  /  誤: EM0:Z1.L (16ビットアクセスに退化する)
  def test_no_suffix_after_index_register
    bad = code_lines(@source).grep(/[A-Z]+\d*:Z\d+\.[SULDF]\b/)
    assert_empty bad,
                 "型サフィックスがインデックスレジスタの後ろに付いています " \
                 "(16ビットアクセスに退化します): #{bad.first(3).inspect}"
  end

  def test_register_access_uses_device_side_suffix
    assert_includes @source, "EM0.L:Z1"
    assert_includes @source, "EM0.L:Z2"
  end

  # === 値スロットのアドレス計算 ===

  # レジスタは「スロット先頭 + 値オフセット」を直接指す
  def test_register_address_matches_slot_layout
    expected = "Z1 = EM7 * #{SLOT_WORDS} + #{REG_FILE_BASE + SLOT_VALUE_OFFSET}"
    assert_includes @source, expected
  end

  def test_pool_address_matches_slot_layout
    expected = "Z2 = EM8 * #{SLOT_WORDS} + #{POOL_BASE + SLOT_VALUE_OFFSET}"
    assert_includes @source, expected
  end

  def test_device_table_stride
    expected = "Z3 = EM8 * #{DEVICE_TABLE_STRIDE} + #{DEVICE_TABLE_BASE}"
    assert_includes @source, expected
  end

  # === オペコードの網羅 ===

  def test_all_table_opcodes_are_emitted
    emitted = @source.scan(/IF EM6 = (\d+) THEN/).flatten.map(&:to_i).sort.uniq
    assert_equal MrubycOnPlc::OpcodeTable.codes.sort, emitted
  end

  def test_unknown_opcode_falls_through_to_error
    assert_includes @source, "EM2 = EM6"
  end

  # === オペランドフェッチが命令形式から生成されている ===

  # OP_MOVE (BB) は 1 バイトオペランドを 2 つ読む
  def test_bb_format_fetches_two_bytes
    body = opcode_body(0x01)
    assert_equal 2, body.scan(/EM0 = EM0 \+ 1/).size
    assert_includes body, "EM7 = EM0:Z1"
    assert_includes body, "EM8 = EM0:Z1"
  end

  # OP_LOADI32 (BSS) は 1 バイト + 16ビット × 2 を読む
  def test_bss_format_fetches_byte_and_two_words
    body = opcode_body(0x0F)
    assert_equal 5, body.scan(/EM0 = EM0 \+ 1/).size
    assert_includes body, "EM8 = Z3 * 256 + Z4"
    assert_includes body, "EM9 = Z3 * 256 + Z4"
  end

  # OP_NOP (Z) はオペランドを読まない
  def test_z_format_fetches_nothing
    refute_includes opcode_body(0x00), "EM0 = EM0 + 1"
  end

  # === デバイスアクセスの分岐 ===

  # ワードデバイス 3 種 × アクセス幅 4 種が生成される
  def test_device_dispatch_covers_all_widths
    body = opcode_body(0x15) # OP_GETGV
    %w[EM DM ZF].each do |dev|
      %w[S U L D].each do |suffix|
        assert_includes body, "#{dev}0.#{suffix}:Z6",
                        "#{dev} デバイスの .#{suffix} アクセスが生成されていない"
      end
    end
  end

  def test_setgv_uses_set_res_for_timer_and_counter
    body = opcode_body(0x16) # OP_SETGV
    assert_includes body, "SET(T0:Z6)"
    assert_includes body, "RES(T0:Z6)"
    assert_includes body, "SET(C0:Z6)"
    assert_includes body, "RES(C0:Z6)"
  end

  # ビットデバイスに幅サフィックスを付けてはいけない (16飛びになる)
  def test_bit_devices_have_no_width_suffix
    bad = code_lines(@source).grep(/\b(R|MR|B|L|T|C)0\.[SULDF]:Z/)
    assert_empty bad, "ビットデバイスに幅サフィックスが付いています: #{bad.first(3).inspect}"
  end

  # === 定義表とエミッタの境界 ===

  # オペコード定義表には PLC 機種固有の名前を書かない。
  # 格納先の実体 (EM7 等) はエミッタが決め、表は e.operand(:b) 経由で参照する。
  # この境界を保っておくと、機種が増えたときにエミッタだけ差し替えられる。
  def test_opcode_table_has_no_device_names
    path = File.expand_path("../tools/opcode_table.rb", __dir__)
    offenders = File.readlines(path, encoding: "UTF-8").each_with_index.filter_map do |l, i|
      next if l.strip.start_with?("#")            # コメントは対象外
      next unless l =~ /\b(EM|DM|ZF|MR)\d+\b|\bZ\d+\b/

      "#{i + 1}: #{l.strip}"
    end

    assert_empty offenders,
                 "オペコード定義表に機種固有のデバイス名が直接書かれています。" \
                 "エミッタのアクセサ (operand / reg / scratch_lo 等) を使ってください:\n" +
                 offenders.join("\n")
  end

  # 逆に、デバイス構文はエミッタに集約されている
  def test_emitter_owns_device_syntax
    path = File.expand_path("../tools/kvs_generator.rb", __dir__)
    src = File.read(path, encoding: "UTF-8")
    assert_includes src, "OPERAND_VARS"
    assert_includes src, "WORD_DEVICES"
    assert_includes src, "BIT_DEVICES"
  end

  # === 構造の健全性 ===

  def test_if_and_end_if_are_balanced
    lines = code_lines(@source)
    opens = lines.count { |l| l.strip.start_with?("IF ") }
    closes = lines.count { |l| l.strip == "END IF" }
    assert_equal opens, closes, "IF と END IF の数が一致しません"
  end

  def test_for_and_next_are_balanced
    lines = code_lines(@source)
    assert_equal lines.count { |l| l.strip.start_with?("FOR ") },
                 lines.count { |l| l.strip == "NEXT" }
  end

  private

  # 指定オペコードの分岐本体を切り出す
  #
  # オペコードの分岐はインデント 8 桁に並ぶ。デバイス分岐の中の
  # ネストした ELSE で切れないよう、インデント幅で判定する。
  OPCODE_INDENT = " " * 8

  def opcode_body(code)
    lines = @source.lines
    start = lines.index { |l| l.rstrip == "#{OPCODE_INDENT}IF EM6 = #{code} THEN" ||
                              l.rstrip == "#{OPCODE_INDENT}ELSE IF EM6 = #{code} THEN" }
    refute_nil start, "オペコード #{code} の分岐が見つからない"

    rest = lines[(start + 1)..]
    stop = rest.index do |l|
      s = l.rstrip
      s == "#{OPCODE_INDENT}ELSE" || s =~ /\A#{OPCODE_INDENT}ELSE IF EM6 = \d+ THEN\z/
    end
    refute_nil stop, "オペコード #{code} の分岐の終端が見つからない"
    rest[0...stop].join
  end
end
