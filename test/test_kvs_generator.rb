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

  PLC_DIR = File.expand_path("../plc/keyence", __dir__)

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
  def test_committed_files_match_generated_output
    FaRuby::KvsGenerator.new.generate.each do |name, content|
      path = File.join(PLC_DIR, name)
      assert_path_exists path, "plc/keyence/#{name} がありません。`rake vm_core` を実行してください。"
      assert_equal content.b, File.binread(path),
                   "plc/keyence/#{name} が生成結果と一致しません。" \
                   "手で編集した場合は tools/opcode_table.rb に反映して `rake vm_core` を実行してください。"
    end
  end

  # 群の数を変えると余りが出る。取り残しは KV Studio に古い中身を取り込む元になる
  def test_no_stale_scripts_are_left_behind
    generated = FaRuby::KvsGenerator.new.generate.keys
    on_disk = Dir[File.join(PLC_DIR, "vm_*.kvs")].map { |p| File.basename(p) }
    assert_empty on_disk - generated,
                 "生成しなくなったスクリプトが残っています。`rake vm_core` を実行してください。"
  end

  # ラダーに並べる順。**前口上と後始末はループの外、取り込みと群は内側**
  #
  # 名前で並べ替えれば置く順になること。取り込むときの取り違えを避けるため。
  def test_generate_returns_the_scripts_in_ladder_order
    files = FaRuby::KvsGenerator.new.generate
    groups = (1..FaRuby::KvsGenerator::DISPATCH_GROUPS).map { |i| "group#{i}" }
    # リセットハンドラが先頭。後ろだと要求のあったスキャンで命令が先に進む
    stems = ["init", "prologue", "instance", "fetch", *groups, "epilogue"]
    expected = stems.each_with_index.map { |stem, i| format("vm_%02d_%s.kvs", i + 1, stem) }

    assert_equal expected, files.keys
    assert_equal expected, files.keys.sort, "名前の順とラダーに置く順が食い違っている"
    files.each_value { |content| refute_empty content }
  end

  # リセットハンドラも生成物。配置に追従しないまま取り残されると
  # 無関係な領域をクリアしてしまう。
  def test_committed_init_matches_generated_output
    name = FaRuby::KvsGenerator.new.file_name("init")
    assert_equal init_source.b, File.binread(File.join(PLC_DIR, name)),
                 "plc/keyence/#{name} が生成結果と一致しません。`rake vm_core` を実行してください。"
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

  # リセットハンドラは1本なので、自分でインスタンスを回す
  def test_the_reset_handler_loops_over_instances
    assert_includes init_source, "FOR Z#{FaRuby::KvsEmitter::Z_INSTANCE} = #{layout.base} " \
                                 "TO #{layout.last_origin} STEP #{layout.instance_size}"
  end

  # 本体のインスタンスループはラダーにある。**回数はスクリプトが渡し、
  # ブロック先頭は頭出しが 1 つずつ進める。**
  def test_the_ladder_is_told_how_many_instances_to_run
    z = "Z#{FaRuby::KvsEmitter::Z_INSTANCE}"
    assert_includes @source, "#{layout.device(layout.ladder_instances_addr)} = #{layout.instances}"
    assert_includes @source, "#{z} = #{layout.base - layout.instance_size}"
    assert_includes @source, "#{z} = #{z} + #{layout.instance_size}"
  end

  # 命令本体は1回だけ生成される (インスタンス数だけ複製しない)
  def test_opcode_bodies_are_not_duplicated_per_instance
    layout3 = FaRuby::MemoryLayout.new(base: layout.base, instances: 3)
    source3 = FaRuby::KvsGenerator.new(layout: layout3).source
    emitter3 = FaRuby::KvsEmitter.new(layout: layout3)

    assert_equal 1, source3.scan("IF #{emitter3.opcode} = 105 THEN").size
    assert_includes source3, "#{layout3.device(layout3.ladder_instances_addr)} = 3"
  end

  # ブロック内の位置は絶対アドレスではなくオフセット + Z9 で指す。
  # 絶対アドレスが残っていると instances > 1 でインスタンス0しか動かない。
  #
  # 例外は Z の退避・復元と、ラダーへ渡す回数だけ。どちらもインスタンス
  # ループの外から触るため、絶対アドレスで指す。
  def test_state_is_addressed_relative_to_the_block
    allowed = FaRuby::KvsEmitter::USED_Z.map { |z| layout.z_save_addr(z) } +
              [layout.ladder_instances_addr, layout.ladder_steps_addr]
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

  # 命令ループの回数も各インスタンスの設定に従う。**ラダーの FOR は途中で
  # 抜けられないため、走らないインスタンスは 0 を渡して丸ごと飛ばす。**
  def test_step_loop_uses_the_instance_own_settings
    steps = layout.device(layout.ladder_steps_addr)
    assert_includes @source, "#{steps} = #{emitter.state(layout.steps_per_cycle_addr)}"
    assert_includes @source, "#{steps} = 0"
  end

  # 止まった後は残りのステップを空回りさせる。**群のスクリプトは
  # ラダーの FOR の中で必ず呼ばれるため、番号で素通りさせるしかない。**
  def test_a_stopped_vm_parks_the_opcode_outside_every_group
    sentinel = FaRuby::KvsGenerator::UNREACHABLE_OPCODE
    dispatch = emitter.state(layout.dispatch_addr)
    assert_includes @source, "IF #{emitter.status} <> #{VM_RUNNING} THEN"
    assert_includes @source, "#{dispatch} = #{sentinel}"

    generator = FaRuby::KvsGenerator.new
    generator.send(:dispatch_groups).each_index do |i|
      assert_operator generator.send(:group_range, i).last, :<, sentinel,
                      "群の範囲が空き番号に届いている"
    end
  end

  # 群は上限だけを見る。**手前の群が実行したら番号を潰す**ので、
  # 後ろの群は比較 1 回で素通りできる。潰すのは本体より先でなければ
  # ならない (本体は BREAK することがあり、後ろに置くと通らない)。
  def test_a_group_clears_the_number_before_running_its_body
    dispatch = emitter.state(layout.dispatch_addr)
    generator = FaRuby::KvsGenerator.new
    files = generator.generate

    generator.send(:dispatch_groups).each_index do |i|
      body = files.fetch(generator.file_name("group#{i + 1}"))
      range = generator.send(:group_range, i)

      assert_includes body, "IF #{dispatch} <= #{range.last} THEN"
      refute_includes body, "IF #{dispatch} >= ", "下限まで見ている (比較が 1 回で済まない)"

      clear = body.index("#{dispatch} = #{FaRuby::KvsGenerator::UNREACHABLE_OPCODE}")
      first_opcode = body.index("IF #{opcode_var} = ")
      refute_nil clear, "群 #{i + 1} が番号を潰していない"
      assert_operator clear, :<, first_opcode, "群 #{i + 1} は本体より先に潰すこと"
    end
  end

  # **実装していない番号が群と群の間に落ちると、どのスクリプトも拾わずに
  # 素通りする。**1 本の連なりだったころは次の組の ELSE が拾っていた。
  # 番号は 0 から最大まで途切れなく、どこかの群が担当していなければならない。
  def test_every_opcode_number_belongs_to_exactly_one_group
    generator = FaRuby::KvsGenerator.new
    ranges = generator.send(:dispatch_groups).each_index.map { |i| generator.send(:group_range, i) }

    assert_equal 0, ranges.first.first, "0 番から始まっていない"
    ranges.each_cons(2) do |a, b|
      assert_equal a.last + 1, b.first, "#{a.last} と #{b.first} の間に抜けがある"
    end
    assert_equal generator.send(:max_opcode), ranges.last.last, "最大の番号まで届いていない"
  end

  # 範囲から外れた番号は取り込みがエラーにする。素通りさせない
  def test_numbers_beyond_the_last_group_are_reported
    max = FaRuby::KvsGenerator.new.send(:max_opcode)
    assert_includes @source, "IF #{emitter.opcode} > #{max} THEN"
    assert_includes @source, "#{emitter.status} = #{VM_ERROR}"
  end

  # BREAK はスクリプトの中で FOR と対になっていなければならない。
  # ステップのループはラダーにあるので、命令を打ち切る BREAK は
  # 1 回だけ回るループで受ける。
  def test_every_group_wraps_its_body_so_break_has_a_partner
    files = FaRuby::KvsGenerator.new.generate
    files.each do |name, content|
      next unless name.start_with?("vm_group")

      next unless content.include?("BREAK")

      assert_includes content, "FOR #{emitter.state(layout.loop_counter_addr)} = 1 TO 1",
                               "#{name} の BREAK に相手がいない"
    end
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
  #
  # 先頭は定数ではなく VM 状態から引く。irep が複数になり、呼び出しごとに
  # レジスタ窓もずれるため、アドレスを焼き込めなくなった。
  def test_register_address_points_at_the_slot_head
    assert_includes @source, "Z1 = #{operand(:a)} * #{SLOT_WORDS} + #{emitter.reg_offset}"
  end

  def test_pool_address_points_at_the_slot_head
    assert_includes @source, "Z2 = #{operand(:b)} * #{SLOT_WORDS} + #{emitter.pool_offset}"
  end

  # 1本の Z でタグ (先頭) と値 (先頭+1) を指す
  def test_slot_reference_covers_tag_and_value
    slot = emitter.reg_slot(:a)
    assert_equal "#{layout.device_name}#{SLOT_TYPE_OFFSET}:Z1", slot.tag
    assert_equal "#{layout.device_name}#{SLOT_VALUE_OFFSET}.L:Z1", slot.value
  end

  def test_device_table_stride
    assert_includes @source, "Z3 = #{operand(:b)} * #{DEVICE_TABLE_STRIDE} + #{emitter.symbols_offset}"
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

  # 実数デバイスへ書くときは整数への変換を行わない。
  #
  # Infinity や NaN を整数へ変換すると浮動小数点フォーマット異常になるため、
  # 両方の形を先に作ると `$DM100F = 1.0 / 0` が PLC のエラーになる。
  def test_device_write_converts_only_what_it_uses
    body = opcode_body(0x16) # OP_SETGV
    to_int = "#{emitter.scratch32} = #{layout.device_name}#{SLOT_VALUE_OFFSET}.F:Z2"

    assert_includes body, to_int, "実数→整数の変換自体はある"
    width_branch = body.index("IF Z8 = #{ACCESS_F} THEN")
    refute_nil width_branch, "アクセス幅で先に分岐する"
    assert_operator width_branch, :<, body.index(to_int),
                    "整数への変換は .F 以外の枝の中だけで行う"
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
    # バイトコードは固定領域 (FM) から読む
    fixed = emitter.fixed_indexed_base
    assert_includes body, "#{operand(:a)} = #{fixed}:Z1"
    assert_includes body, "#{operand(:b)} = #{fixed}:Z1"
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

  # ビットデバイスへの書き込みは種類によらず TRUE / FALSE の代入
  #
  # 以前はタイマ・カウンタの接点だけ `SET` / `RES` を使っていましたが、
  # 代入でも書けるため分けていません。ST も同じ形で書けます。
  def test_writing_a_bit_device_assigns_true_or_false
    body = opcode_body(0x16) # OP_SETGV
    %w[R MR B LR T C].each do |dev|
      assert_includes body, "#{dev}0:Z6 = TRUE", "#{dev} を ON にする代入"
      assert_includes body, "#{dev}0:Z6 = FALSE", "#{dev} を OFF にする代入"
    end
    refute_includes body, "SET(", "SET / RES は使わない"
  end

  # ビットデバイスは幅の有無で経路が分かれる。
  # 無しなら個別ビット、有りなら整数 (MR 等はビット列、T / C は現在値)。
  def test_bit_devices_have_both_paths
    %w[MR R B LR T C].each do |dev|
      assert_includes @source, "#{dev}0:Z6", "#{dev} の個別ビットアクセス"
      assert_includes @source, "#{dev}0.L:Z6", "#{dev} の幅付きアクセス"
    end
  end

  def test_bit_access_is_selected_by_the_width
    assert_includes @source, "IF Z8 = #{ACCESS_BIT} THEN"
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

  # === KV Studio の上限 ===

  # 1 スクリプトの文字数。**取り込むまで分からないので、ここで見る**
  #
  # 超えると KV Studio が変換を拒む。字下げが全体の 4 割を占めるので、
  # 詰まってきたら刻みを狭めるのがいちばん安い。詳細は
  # doc/architecture.md の「KV Studio の変換上限」。
  SCRIPT_LIMIT = 264_144

  def test_the_scripts_fit_in_one_script
    FaRuby::KvsGenerator.new.generate.each do |name, source|
      assert_operator source.bytesize, :<=, SCRIPT_LIMIT,
                      "#{name} が 1 スクリプトの上限を超えている"
    end
  end

  # 余裕がどれくらい残っているかを目に見えるようにしておく
  #
  # **上限はスクリプトごとなので、いちばん大きいものだけを見る。**
  # 近づいたら群を増やして分け直せる (ラダーは箱を足すだけ)。
  def test_every_script_has_room_left
    largest = FaRuby::KvsGenerator.new.generate.max_by { |_, source| source.bytesize }

    assert_operator largest.last.bytesize, :<, SCRIPT_LIMIT * 95 / 100,
                    "#{largest.first} が上限の 95% を超えた。DISPATCH_GROUPS を増やすころ合い"
  end

  private

  # 指定オペコードの分岐本体を切り出す
  #
  # デバイス分岐の中のネストした ELSE で切れないよう、インデント幅で
  # 判定する。**幅は見つけた分岐そのものから読みます。**群ごとに
  # スクリプトが分かれ、包む IF の数が群によって違うためです
  # (0 番から始まる群だけ下限の判定が要らない)。
  def opcode_body(code)
    lines = @source.lines
    head = /\A( *)(ELSE )?IF #{Regexp.escape(opcode_var)} = #{code} THEN\z/
    start = lines.index { |l| l.rstrip =~ head }
    refute_nil start, "オペコード #{code} の分岐が見つからない"
    indent = lines[start].rstrip[head, 1]

    rest = lines[(start + 1)..]
    stop = rest.index do |l|
      s = l.rstrip
      s == "#{indent}ELSE" || s =~ /\A#{indent}ELSE IF #{Regexp.escape(opcode_var)} = \d+ THEN\z/
    end
    refute_nil stop, "オペコード #{code} の分岐の終端が見つからない"
    rest[0...stop].join
  end
end
