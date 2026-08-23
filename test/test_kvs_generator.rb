# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"

# KV スクリプト生成器のテスト
class TestKvsGenerator < Minitest::Test
  include FaRuby::VmConstants

  # テストは既定レイアウト (faruby_default.yml) を使う。
  # 利用者の faruby.yml に影響されないようにするため。
  def layout = FaRuby::MemoryLayout.default

  # 生成コードに現れるデバイス名は配置から決まるため、テストも配置から導く。
  # 生成コードはブロック相対 (EM7:Z9) なので、テストも emitter 経由で組み立てる。
  def emitter      = @emitter ||= FaRuby::KvsEmitter.new(layout: layout)
  def operand(name) = emitter.operand(name)
  def pc           = emitter.pc
  def indexed_base = emitter.indexed_base
  def opcode_var   = emitter.opcode

  # PC を1つ進める行の出現回数を数える
  def count_pc_increments(body)
    body.scan(/#{Regexp.escape("#{pc} = #{pc} + 1")}/).size
  end

  VM_CORE_PATH = File.expand_path("../plc/keyence/vm_core.kvs", __dir__)
  VM_INIT_PATH = File.expand_path("../plc/keyence/vm_init.kvs", __dir__)

  def setup
    @source = FaRuby::KvsGenerator.new.source
  end

  def init_source = @init_source ||= FaRuby::KvsGenerator.new.init_source

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
    files = FaRuby::KvsGenerator.new.generate
    assert_equal ["vm_core.kvs", "vm_init.kvs"], files.keys.sort
    files.each_value { |content| refute_empty content }
  end

  # リセットハンドラも生成物。配置に追従しないまま取り残されると
  # 無関係な領域をクリアしてしまう。
  def test_committed_init_matches_generated_output
    assert_equal init_source.b, File.binread(VM_INIT_PATH),
                 "plc/keyence/vm_init.kvs が生成結果と一致しません。`rake vm_core` を実行してください。"
  end

  def test_init_clears_the_register_file_of_the_current_layout
    from = emitter.block_offset(layout.reg_file_base)
    to   = emitter.block_offset(layout.reg_slot_addr(layout.max_regs) - 1)
    assert_includes init_source, "FOR Z#{FaRuby::KvsEmitter::Z_PRIMARY} = #{from} TO #{to}"
  end

  def test_init_resets_vm_state_of_the_current_layout
    assert_includes init_source, "#{emitter.pc} = 0"
    assert_includes init_source, "#{emitter.status} = #{VM_STOPPED}"
    assert_includes init_source, "IF #{emitter.state(layout.reset_req_addr)} = 1 THEN"
  end

  # === インスタンスループ ===

  # 本体は1つで、ブロック先頭を Z9 に載せ替えて全インスタンスを回す
  def test_both_scripts_loop_over_instances
    header = "FOR Z#{FaRuby::KvsEmitter::Z_INSTANCE} = #{layout.base} " \
             "TO #{layout.last_origin} STEP #{layout.instance_size}"
    assert_includes @source, header
    assert_includes init_source, header
  end

  # 命令本体は1回だけ生成される (インスタンス数だけ複製しない)
  def test_opcode_bodies_are_not_duplicated_per_instance
    layout3 = FaRuby::MemoryLayout.new(base: layout.base, instances: 3)
    source3 = FaRuby::KvsGenerator.new(layout: layout3).source
    emitter3 = FaRuby::KvsEmitter.new(layout: layout3)

    assert_equal 1, source3.scan("IF #{emitter3.opcode} = 105 THEN").size
    assert_includes source3, "FOR Z#{FaRuby::KvsEmitter::Z_INSTANCE} = #{layout3.base} " \
                             "TO #{layout3.last_origin} STEP #{layout3.instance_size}"
  end

  # ブロック内の位置は絶対アドレスではなくオフセット + Z9 で指す。
  # 絶対アドレスが残っていると instances > 1 でインスタンス0しか動かない。
  #
  # 例外は Z の退避・復元だけ。これはインスタンスループの外で1回だけ動く。
  def test_state_is_addressed_relative_to_the_block
    allowed = FaRuby::KvsEmitter::USED_Z.map { |z| layout.z_save_addr(z) }
    offenders = code_lines(@source).select do |l|
      l.scan(/\b#{layout.device_name}(\d+)/).flatten.map(&:to_i)
       .any? { |n| n >= layout.base && !allowed.include?(n) }
    end
    assert_empty offenders,
                 "ブロック内を絶対アドレスで指している行があります " \
                 "(instances > 1 でインスタンス0しか動きません): #{offenders.first(3).inspect}"
  end

  # 実行判定は各インスタンスの STATUS を見る
  def test_each_instance_checks_its_own_status
    assert_includes @source, "IF #{emitter.status} = #{VM_RUNNING} THEN"
  end

  # 命令ループの回数も各インスタンスの設定に従う
  def test_step_loop_uses_the_instance_own_settings
    assert_includes @source, "FOR #{emitter.state(layout.loop_counter_addr)} = 1 " \
                             "TO #{emitter.state(layout.steps_per_cycle_addr)}"
  end

  # === Z レジスタの退避・復元 ===

  # Z はラダーと共有する資源なので、faRuby の実行前後で内容が変わってはいけない
  def test_used_z_registers_are_saved_and_restored
    FaRuby::KvsEmitter::USED_Z.each do |z|
      save = layout.device(layout.z_save_addr(z))
      assert_includes @source, "#{save} = Z#{z}", "Z#{z} が退避されていない"
      assert_includes @source, "Z#{z} = #{save}", "Z#{z} が復元されていない"
    end
  end

  # 退避は命令ごとではなく1スキャンにつき1回
  def test_z_is_saved_once_per_scan
    z = FaRuby::KvsEmitter::Z_PRIMARY
    save = layout.device(layout.z_save_addr(z))
    assert_equal 1, @source.scan("#{save} = Z#{z}").size
    assert_equal 1, @source.scan("Z#{z} = #{save}").size
  end

  # 宣言していない Z を使っていないこと (退避漏れになる)
  # 判定はコード行のみ。コメントは使えない Z にも言及するため。
  def test_no_undeclared_z_registers_are_used
    used = code_lines(@source).join("\n").scan(/\bZ(\d+)\b/).flatten.map(&:to_i).uniq.sort
    unexpected = used - FaRuby::KvsEmitter::USED_Z
    assert_empty unexpected,
                 "USED_Z に無い Z レジスタを使っています (退避されません): " \
                 "#{unexpected.map { |z| "Z#{z}" }.join(', ')}"
  end

  # 退避先が VM 状態領域に収まっていること
  def test_z_save_area_fits_in_the_vm_state_region
    last = layout.z_save_addr(FaRuby::KvsEmitter::USED_Z.last)
    assert_operator last, :<, layout.reg_file_base
  end

  # 退避先とレジスタファイル等が重ならないこと
  def test_z_save_area_does_not_collide_with_other_state
    others = [layout.pc_addr, layout.status_addr, layout.error_addr,
              layout.step_count_addr, layout.step_count_addr + 1,
              layout.steps_per_cycle_addr, layout.current_opcode_addr,
              layout.operand_a_addr, layout.operand_b_addr, layout.operand_c_addr,
              layout.bytecode_len_addr, layout.nregs_addr, layout.nlocals_addr,
              layout.reset_req_addr, layout.num_symbols_addr,
              layout.temp32_addr, layout.temp32_addr + 1, layout.loop_counter_addr]
    saves = FaRuby::KvsEmitter::USED_Z.map { |z| layout.z_save_addr(z) }
    assert_empty(saves & others, "Z の退避先が他の VM 状態と重なっています")
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
    assert_includes @source, "#{layout.device_name}#{SLOT_VALUE_OFFSET}.L:Z1"
    assert_includes @source, "#{layout.device_name}#{SLOT_VALUE_OFFSET}.L:Z2"
  end

  # === 値スロットのアドレス計算 ===

  # Z はスロット先頭を指し、タグと値の両方を1本で扱う
  def test_register_address_points_at_the_slot_head
    base = emitter.block_offset(layout.reg_file_base)
    assert_includes @source, "Z1 = #{operand(:a)} * #{SLOT_WORDS} + #{base}"
  end

  def test_pool_address_points_at_the_slot_head
    base = emitter.block_offset(layout.pool_base)
    assert_includes @source, "Z2 = #{operand(:b)} * #{SLOT_WORDS} + #{base}"
  end

  # 1本の Z でタグ (先頭) と値 (先頭+1) を指す
  def test_slot_reference_covers_tag_and_value
    slot = emitter.reg_slot(:a)
    assert_equal "#{layout.device_name}#{SLOT_TYPE_OFFSET}:Z1", slot.tag
    assert_equal "#{layout.device_name}#{SLOT_VALUE_OFFSET}.L:Z1", slot.value
  end

  def test_device_table_stride
    base = emitter.block_offset(layout.device_table_base)
    assert_includes @source, "Z3 = #{operand(:b)} * #{DEVICE_TABLE_STRIDE} + #{base}"
  end

  # 実数の 0 除算では、代入先を書き換える前に符号を確定させる。
  #
  # 代入先は被除数と同じレジスタなので、低位ワードを消してから符号を見ると
  # 整数の 1-65535 が 0 になり、+Infinity が NaN になる。実機で確認した不具合。
  # シミュレータは Ruby の値で計算するため、この順序は生成コードでしか守れない。
  def test_float_division_by_zero_decides_the_sign_before_writing
    body = opcode_body(0x41)
    hi = "#{layout.device_name}#{SLOT_VALUE_OFFSET + 1}:Z1"

    assert_includes body, "#{hi} = #{emitter.scratch_lo}",
                    "上位ワードはスクラッチ経由で書く"
    refute_match(/#{Regexp.escape(hi)} = \d/, body,
                 "符号ごとに上位ワードを直接書くと、被除数を壊してから符号を見ることになる")
  end

  # === オペコードの網羅 ===

  def test_all_table_opcodes_are_emitted
    emitted = @source.scan(/IF #{Regexp.escape(opcode_var)} = (\d+) THEN/).flatten.map(&:to_i).sort.uniq
    assert_equal FaRuby::OpcodeTable.codes.sort, emitted
  end

  def test_unknown_opcode_falls_through_to_error
    assert_includes @source, "#{emitter.error} = #{opcode_var}"
  end

  # === オペランドフェッチが命令形式から生成されている ===

  # OP_MOVE (BB) は 1 バイトオペランドを 2 つ読む
  def test_bb_format_fetches_two_bytes
    body = opcode_body(0x01)
    assert_equal 2, count_pc_increments(body)
    assert_includes body, "#{operand(:a)} = #{indexed_base}:Z1"
    assert_includes body, "#{operand(:b)} = #{indexed_base}:Z1"
  end

  # OP_LOADI32 (BSS) は 1 バイト + 16ビット × 2 を読む
  def test_bss_format_fetches_byte_and_two_words
    body = opcode_body(0x0F)
    assert_equal 5, count_pc_increments(body)
    assert_includes body, "#{operand(:b)} = Z3 * 256 + Z4"
    assert_includes body, "#{operand(:c)} = Z3 * 256 + Z4"
  end

  # OP_NOP (Z) はオペランドを読まない
  def test_z_format_fetches_nothing
    refute_includes opcode_body(0x00), "#{pc} = #{pc} + 1"
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
    assert_includes src, "OPERAND_NAMES"
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
  # オペコードの分岐はすべて同じ深さに並ぶ。デバイス分岐の中の
  # ネストした ELSE で切れないよう、インデント幅で判定する。
  # 幅は生成物から読む (入れ子が変わっても追従する)。
  def opcode_indent
    @opcode_indent ||= begin
      head = @source.lines.find { |l| l =~ /\A\s*IF #{Regexp.escape(opcode_var)} = \d+ THEN\s*\z/ }
      refute_nil head, "オペコードの分岐が1つも見つからない"
      head[/\A */]
    end
  end

  def opcode_body(code)
    indent = opcode_indent
    lines = @source.lines
    start = lines.index { |l| l.rstrip == "#{indent}IF #{opcode_var} = #{code} THEN" ||
                              l.rstrip == "#{indent}ELSE IF #{opcode_var} = #{code} THEN" }
    refute_nil start, "オペコード #{code} の分岐が見つからない"

    rest = lines[(start + 1)..]
    stop = rest.index do |l|
      s = l.rstrip
      s == "#{indent}ELSE" || s =~ /\A#{indent}ELSE IF #{Regexp.escape(opcode_var)} = \d+ THEN\z/
    end
    refute_nil stop, "オペコード #{code} の分岐の終端が見つからない"
    rest[0...stop].join
  end
end
