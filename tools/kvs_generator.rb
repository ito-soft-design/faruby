# frozen_string_literal: true

# KV スクリプト生成器
#
# tools/opcode_table.rb の定義から plc/keyence/vm_core.kvs を生成します。
# 再生成は `rake vm_core`。
#
# 手書きしていた頃に繰り返し発生した以下の不具合を、イディオムを1箇所に
# 集約することで防ぐのが目的です。
#   - 型サフィックスの位置 (EM0:Z1.L と書くと16ビットに退化する) が91箇所
#   - 値スロットのストライド変更が45箇所
#   - vm_core.kvs にだけ命令の実装が漏れる (OP_LOADNIL)

require_relative "memory_map"
require_relative "opcode_table"

module MrubycOnPlc
  # KV スクリプトの行を組み立てるエミッタ
  #
  # デバイスアクセスのイディオムはすべてここに集約されています。
  # 「型サフィックスはデバイス側に付ける (EM0.L:Z1)」という規則も
  # このクラスの中だけで守れば全命令に反映されます。
  class KvsEmitter
    include MemoryMap

    INDENT = "    "

    # オペランド名 → 格納先 EM デバイス
    OPERAND_VARS = { a: "EM7", b: "EM8", c: "EM9" }.freeze

    # 命令形式 → 各オペランドのバイト数
    FORMAT_OPERANDS = {
      Z: [], B: [1], BB: [1, 1], BBB: [1, 1, 1],
      S: [2], BS: [1, 2], BSS: [1, 2, 2],
    }.freeze

    # ワードデバイス (アクセス幅の選択が必要)
    WORD_DEVICES = [[DEVICE_TYPE_EM, "EM"], [DEVICE_TYPE_DM, "DM"], [DEVICE_TYPE_ZF, "ZF"]].freeze

    # ビットデバイス。set_res が true のものは代入ではなく SET/RES を使う
    BIT_DEVICES = [
      [DEVICE_TYPE_R,  "R",  false], [DEVICE_TYPE_MR, "MR", false],
      [DEVICE_TYPE_B,  "B",  false], [DEVICE_TYPE_L,  "L",  false],
      [DEVICE_TYPE_T,  "T",  true],  [DEVICE_TYPE_C,  "C",  true],
    ].freeze

    # アクセス幅の分岐順。最後の要素 (.S) が ELSE になる
    ACCESS_BRANCHES = [[ACCESS_L, "L"], [ACCESS_U, "U"], [ACCESS_D, "D"]].freeze
    ACCESS_DEFAULT_SUFFIX = "S"

    attr_reader :lines

    def initialize(level: 0)
      @lines = []
      @level = level
    end

    # --- 基本 ---

    def line(text)
      @lines << (INDENT * @level + text)
    end

    def blank
      @lines << ""
    end

    def comment(text)
      line(text.empty? ? "'" : "' #{text}")
    end

    def indent
      @level += 1
    end

    def dedent
      @level -= 1
    end

    # IF cond THEN <block> END IF
    def if_block(cond)
      line "IF #{cond} THEN"
      indent
      yield
      dedent
      line "END IF"
    end

    # IF cond THEN <block> ELSE  ... 呼び出し側が ELSE 本体を出し end_block で閉じる
    def if_else_block(cond)
      line "IF #{cond} THEN"
      indent
      yield
      dedent
      line "ELSE"
      indent
    end

    def end_block
      dedent
      line "END IF"
    end

    # --- VM 状態・オペランドへの参照 ---
    #
    # 定義表 (opcode_table.rb) が EM7 などの機種固有の名前を直接書かずに
    # 済むよう、参照はすべてここを経由します。

    # オペランド a / b / c の格納先
    def operand(name)
      OPERAND_VARS.fetch(name)
    end

    def pc     = MemoryMap.device(PC_ADDR)
    def status = MemoryMap.device(STATUS_ADDR)

    # VM を正常終了させる
    def vm_finish
      line "#{status} = #{VM_FINISHED}"
      line "BREAK"
    end

    # VM をエラー停止させる
    def vm_error(code)
      line "#{status} = #{VM_ERROR}"
      line "#{MemoryMap.device(ERROR_ADDR)} = #{code}"
      line "BREAK"
    end

    # PC を相対ジャンプさせる
    # PC も16ビット符号なしのため、加算が16ビットの剰余演算になることで
    # 後方ジャンプ (負のオフセット) が成立する
    def jump_relative(name)
      line "#{pc} = #{pc} + #{operand(name)}"
    end

    # --- 値スロットへのアクセス (イディオムの集約点) ---

    # R[operand] の値を Z<z> 経由で参照する式を返す
    def reg(z, operand)
      addr_expr(z, "#{OPERAND_VARS.fetch(operand)} * #{SLOT_WORDS}", reg_value_base)
    end

    # R[operand + 1] の値を参照する式を返す
    def reg_next(z, operand)
      addr_expr(z, "(#{OPERAND_VARS.fetch(operand)} + 1) * #{SLOT_WORDS}", reg_value_base)
    end

    # Pool[operand] の値を参照する式を返す
    def pool(z, operand)
      addr_expr(z, "#{OPERAND_VARS.fetch(operand)} * #{SLOT_WORDS}", pool_value_base)
    end

    # 32ビット合成スクラッチ
    def scratch_lo = MemoryMap.device(TEMP32_ADDR)
    def scratch_hi = MemoryMap.device(TEMP32_ADDR + 1)
    def scratch32  = MemoryMap.device_long(TEMP32_ADDR)

    # --- オペランドフェッチ (命令形式から自動生成) ---

    def fetch_operands(format)
      FORMAT_OPERANDS.fetch(format).each_with_index do |bytes, i|
        target = OPERAND_VARS.values[i]
        bytes == 1 ? fetch_byte(target) : fetch_u16(target)
      end
    end

    # 16ビットオペランドを符号付きとして解釈する
    # EM は16ビット符号なしのため引き算しても同じビット列だが、
    # PC への加算が16ビットの剰余演算になることで後方ジャンプが成立する
    def signed16(name)
      var = operand(name)
      if_block("#{var} >= 32768") { line "#{var} = #{var} - 65536" }
    end

    # オペランドを符号拡張して32ビットスクラッチに置く
    # bits: 元の値のビット幅 (8 または 16)
    def sign_extend_to_scratch(name, bits)
      var = operand(name)
      threshold = 1 << (bits - 1)
      line "#{scratch_lo} = #{var}"
      line "#{scratch_hi} = 0"
      if_block("#{var} >= #{threshold}") do
        # 8ビットの場合は下位ワードも16ビットへ符号拡張する必要がある
        line "#{scratch_lo} = #{var} + #{0x1_0000 - (1 << bits)}" if bits < 16
        line "#{scratch_hi} = 65535"
      end
    end

    # --- デバイスアクセス ---

    # デバイスマッピングテーブルから type / address / access_type を読む
    def device_table_lookup(operand)
      comment "デバイスマッピングテーブル参照 (#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      line "Z3 = #{OPERAND_VARS.fetch(operand)} * #{DEVICE_TABLE_STRIDE} + #{DEVICE_TABLE_BASE}"
      line "Z4 = Z3 + 1"
      line "Z5 = EM0:Z3"
      line "Z6 = EM0:Z4"
      line "Z7 = Z3 + 2"
      line "Z8 = EM0:Z7"
    end

    # デバイス種別 × アクセス幅の分岐を生成する
    # mode: :read (デバイス → レジスタ) / :write (レジスタ → デバイス)
    def device_dispatch(mode, reg:, error_code:)
      comment "デバイスタイプ別#{mode == :read ? '読み取り' : '書き込み'}"
      comment "ワードデバイス (EM, DM, ZF): Z8 (access_type) で幅を選ぶ"
      ACCESS_BRANCHES.each do |value, suffix|
        comment "  #{value}=.#{suffix}(#{ACCESS_NAMES.fetch(value)})"
      end
      comment "  それ以外=.#{ACCESS_DEFAULT_SUFFIX}(#{ACCESS_NAMES.fetch(ACCESS_S)}/既定)"
      comment "ビットデバイス (R, MR, B, L, T, C): #{mode == :read ? '個別ビット → 0/1' : '非0→ON, 0→OFF'}"

      first = true
      WORD_DEVICES.each do |type, name|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        word_device_body(mode, name, reg)
        dedent
      end

      BIT_DEVICES.each do |type, name, set_res|
        chain_head(first, "Z5 = #{type}")
        first = false
        indent
        bit_device_body(mode, name, reg, set_res)
        dedent
      end

      line "ELSE"
      indent
      vm_error(error_code)
      dedent
      line "END IF"
    end

    private

    # レジスタ/プールの「値ワード」の先頭アドレス
    def reg_value_base  = REG_FILE_BASE + SLOT_VALUE_OFFSET
    def pool_value_base = POOL_BASE + SLOT_VALUE_OFFSET

    # Z<z> にアドレスを設定し、32ビットアクセス式を返す
    #
    # 型サフィックスはデバイス側に付ける (EM0.L:Z1)。
    # EM0:Z1.L と書くと .L がインデックスレジスタに結合し、
    # エラーにならないまま16ビットアクセスに退化する。
    def addr_expr(z, index_expr, base)
      line "Z#{z} = #{index_expr} + #{base}"
      "#{DEVICE_NAME}0.L:Z#{z}"
    end

    # バイトコードの現在位置を Z1 経由で読み、PC を1つ進める
    def read_bytecode_into(dest)
      line "Z1 = #{pc} + #{BYTECODE_BASE}"
      line "#{dest} = #{DEVICE_NAME}0:Z1"
      line "#{pc} = #{pc} + 1"
    end

    def fetch_byte(target)
      read_bytecode_into(target)
    end

    # 16ビットビッグエンディアン (上位バイトが先)
    def fetch_u16(target)
      comment "16bit big-endian: hi byte, lo byte"
      read_bytecode_into("Z3")
      read_bytecode_into("Z4")
      line "#{target} = Z3 * 256 + Z4"
    end

    def chain_head(first, cond)
      line(first ? "IF #{cond} THEN" : "ELSE IF #{cond} THEN")
    end

    def word_device_body(mode, name, reg)
      first = true
      ACCESS_BRANCHES.each do |value, suffix|
        chain_head(first, "Z8 = #{value}")
        first = false
        indent
        line word_assignment(mode, name, suffix, reg)
        dedent
      end
      line "ELSE"
      indent
      line word_assignment(mode, name, ACCESS_DEFAULT_SUFFIX, reg)
      dedent
      line "END IF"
    end

    def word_assignment(mode, name, suffix, reg)
      device = "#{name}0.#{suffix}:Z6"
      mode == :read ? "#{reg} = #{device}" : "#{device} = #{reg}"
    end

    def bit_device_body(mode, name, reg, set_res)
      bit = "#{name}0:Z6"
      if mode == :read
        if_else_block(bit) { line "#{reg} = 1" }
        line "#{reg} = 0"
        end_block
      elsif set_res
        if_else_block("#{reg} <> 0") { line "SET(#{bit})" }
        line "RES(#{bit})"
        end_block
      else
        if_else_block("#{reg} <> 0") { line "#{bit} = 1" }
        line "#{bit} = 0"
        end_block
      end
    end
  end

  # vm_core.kvs を生成する
  #
  # generate は { ファイル名 => 内容 } を返します。現在は 1 ファイルですが、
  # KV Studio がスクリプトの大きさで変換できなくなった場合に分割できるよう
  # 複数ファイルを返せる形にしてあります。
  class KvsGenerator
    include MemoryMap

    OUTPUT_NAME = "vm_core.kvs"
    OUTPUT_DIR  = File.expand_path("../plc/keyence", __dir__)

    def initialize(opcodes = OpcodeTable.all)
      @opcodes = opcodes
    end

    def generate
      { OUTPUT_NAME => build_source }
    end

    # 単一ファイルの内容を返す (テスト・比較用)
    def source
      generate.fetch(OUTPUT_NAME)
    end

    # 生成結果をファイルに書き出す。書き換わったファイル名を返す
    def write!(dir = OUTPUT_DIR)
      generate.filter_map do |name, content|
        path = File.join(dir, name)
        next if File.exist?(path) && File.binread(path) == content.b

        File.binwrite(path, content)
        name
      end
    end

    private

    def build_source
      e = KvsEmitter.new
      emit_header(e)
      e.blank
      e.line "IF EM1 = #{VM_RUNNING} THEN"
      e.blank
      e.indent
      e.line "FOR EM20 = 1 TO #{MemoryMap.device(STEPS_PER_CYCLE)}"
      e.blank
      e.indent
      emit_fetch(e)
      emit_dispatch(e)
      emit_range_check(e)
      e.dedent
      e.line "NEXT"
      e.blank
      e.dedent
      e.line "END IF"
      "#{e.lines.join("\n")}\n"
    end

    def emit_header(e)
      e.comment "======================================="
      e.comment "mruby/c VM Core - Fetch/Decode/Execute"
      e.comment "======================================="
      e.comment "【自動生成】このファイルを直接編集しないでください。"
      e.comment "  定義: tools/opcode_table.rb"
      e.comment "  生成: tools/kvs_generator.rb  (rake vm_core)"
      e.comment "  編集した場合 test_kvs_generator.rb が失敗します。"
      e.comment ""
      e.comment "EM デバイスを使用。"
      e.comment "EM0  = PC (プログラムカウンタ)"
      e.comment "EM1  = STATUS (0=停止, 1=実行中, 2=完了, 3=エラー)"
      e.comment "EM2  = ERROR"
      e.comment "EM5  = STEPS_PER_CYCLE"
      e.comment "EM6  = CURRENT_OPCODE (デバッグ用)"
      e.comment "EM7  = operand a"
      e.comment "EM8  = operand b"
      e.comment "EM9  = operand c"
      e.comment "EM13 = RESET_REQ (1=リセット要求, vm_init で処理)"
      e.comment "EM#{TEMP32_ADDR} = 32ビット合成スクラッチ 下位ワード"
      e.comment "EM#{TEMP32_ADDR + 1} = 32ビット合成スクラッチ 上位ワード"
      e.comment "       EM は無サフィックスだと16ビット符号なしのため、負値や"
      e.comment "       65535 超の即値は一旦この2ワードに置いてから .L で読む"
      e.comment "EM#{REG_FILE_BASE}~ = レジスタファイル (値スロット #{SLOT_WORDS}ワード/レジスタ)"
      e.comment "EM#{BYTECODE_BASE}~ = バイトコード (1バイト/1EM)"
      e.comment "EM#{POOL_BASE}~ = 定数プール (値スロット #{SLOT_WORDS}ワード/エントリ)"
      e.comment "EM#{DEVICE_TABLE_BASE}~ = デバイスマッピングテーブル (#{DEVICE_TABLE_STRIDE}ワード/エントリ)"
      e.comment ""
      e.comment "Z1-Z8 を間接アドレッシングに使用"
      e.comment ""
      e.comment "【重要】インデックス修飾と型サフィックスの順序"
      e.comment "  正: EM0.L:Z1   デバイスに .L が付く → 32ビットアクセス"
      e.comment "  誤: EM0:Z1.L   .L がインデックスレジスタ Z1 に結合してしまい、"
      e.comment "                 エラーにならないまま16ビットアクセスになる"
      e.comment "  インデックスの刻み幅は .L でも 1 ワード。下位ワードが先。"
    end

    def emit_fetch(e)
      e.comment "=== FETCH OPCODE ==="
      e.line "Z1 = EM0 + #{BYTECODE_BASE}"
      e.line "EM6 = EM0:Z1"
      e.line "EM0 = EM0 + 1"
      e.blank
    end

    def emit_dispatch(e)
      e.comment "=== DECODE & EXECUTE ==="
      e.blank

      @opcodes.each_with_index do |op, i|
        e.line(i.zero? ? "IF EM6 = #{op.code} THEN" : "ELSE IF EM6 = #{op.code} THEN")
        e.indent
        e.comment op.header_comment
        e.fetch_operands(op.format)
        op.body&.call(e)
        e.dedent
        e.blank
      end

      e.line "ELSE"
      e.indent
      e.comment "未知のオペコード: エラー"
      e.line "EM1 = #{VM_ERROR}"
      e.line "EM2 = EM6"
      e.line "BREAK"
      e.dedent
      e.blank
      e.line "END IF"
      e.blank
    end

    def emit_range_check(e)
      e.comment "バイトコード範囲チェック"
      e.if_block("EM0 >= #{MemoryMap.device(BYTECODE_LEN_ADDR)}") do
        e.line "EM1 = #{VM_FINISHED}"
        e.line "BREAK"
      end
      e.blank
    end
  end
end

# コマンドラインから実行した場合は標準出力に生成結果を出す
if __FILE__ == $0
  puts MrubycOnPlc::KvsGenerator.new.source
end
