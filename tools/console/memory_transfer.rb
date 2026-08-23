# frozen_string_literal: true

# メモリ転送
# PlcCodegen#memory_image の Hash を PLC に効率的に書き込み、
# PLC から VM 状態やレジスタを読み出します。

require_relative "../vm_constants"
require_relative "../memory_layout"
require_relative "plc_adapters/base"

module FaRuby
  module Console
    class MemoryTransfer
      include VmConstants

      STATUS_LABELS = {
        VM_STOPPED => "停止",
        VM_RUNNING => "実行中",
        VM_FINISHED => "完了",
        VM_ERROR => "エラー",
      }.freeze

      # 対象インスタンスの切り替えで差し替わる
      attr_accessor :layout

      def initialize(adapter, layout: MemoryLayout.default)
        @adapter = adapter
        @layout = layout
      end

      # memory_image Hash を PLC に書き込む
      # 連続アドレスをグループ化して一括転送する
      def write_image(image)
        runs = group_consecutive(normalize_image(image))
        total = 0
        runs.each do |start_addr, values|
          @adapter.write_words(start_addr, values)
          total += values.size
        end
        total
      end

      # VM 状態を PLC から読み出す
      #
      # read_words は先頭からの相対配列を返すため、絶対アドレスではなく
      # VM 状態領域の先頭からのオフセットで引く
      def read_vm_state
        base = layout.vm_state_base
        words = @adapter.read_words(base, MemoryLayout::VM_STATE_WORDS)
        at = ->(addr) { words[addr - base] }
        status = at.(layout.status_addr)
        {
          pc:              at.(layout.pc_addr),
          status:          status,
          status_label:    STATUS_LABELS[status] || "不明(#{status})",
          error:           at.(layout.error_addr),
          step_count:      at.(layout.step_count_addr) | (at.(layout.step_count_addr + 1) << 16),
          steps_per_cycle: at.(layout.steps_per_cycle_addr),
          current_opcode:  at.(layout.current_opcode_addr),
          operand_a:       at.(layout.operand_a_addr),
          operand_b:       at.(layout.operand_b_addr),
          operand_c:       at.(layout.operand_c_addr),
          bytecode_len:    at.(layout.bytecode_len_addr),
          nregs:           at.(layout.nregs_addr),
          nlocals:         at.(layout.nlocals_addr),
          reset_req:       at.(layout.reset_req_addr),
        }
      end

      # レジスタファイルを PLC から読み出す
      def read_registers(nregs = nil, nlocals = nil)
        unless nregs
          meta = @adapter.read_words(layout.nregs_addr, 2)
          nregs = meta[0]
          nlocals = meta[1]
        end
        nregs = [nregs, layout.max_regs].min
        nlocals ||= 0

        # 値スロット (SLOT_WORDS ワード/レジスタ) をまとめて読む
        words = @adapter.read_words(layout.reg_file_base, nregs * SLOT_WORDS)
        regs = []
        nregs.times do |i|
          slot = i * SLOT_WORDS
          type = words[slot + SLOT_TYPE_OFFSET] & 0xFFFF
          lo = words[slot + SLOT_VALUE_OFFSET] & 0xFFFF
          hi = words[slot + SLOT_VALUE_OFFSET + 1] & 0xFFFF
          val = (hi << 16) | lo
          # 実数は同じ2ワードが IEEE754 単精度のビット列
          if type == TT_FLOAT
            val = [val].pack("V").unpack1("e")
          else
            val -= 0x1_0000_0000 if val >= 0x8000_0000
          end

          label = if i == 0
                    "self"
                  elsif i < nlocals
                    "local"
                  else
                    "temp"
                  end
          regs << { index: i, value: val, label: label, type: type,
                    display: display_value(type, val) }
        end
        regs
      end

      # 型タグに応じた表示
      #
      # 値だけを出すと nil も false も 0 も同じに見えてしまう
      def display_value(type, value)
        case type
        when TT_NIL    then "nil"
        when TT_TRUE   then "true"
        when TT_FALSE  then "false"
        when TT_OBJECT then "self"
        when TT_EMPTY  then "-"
        else                value.to_s
        end
      end

      # VM STATUS を書き込む
      def write_status(value)
        @adapter.write_word(layout.status_addr, value)
      end

      # メモリイメージと PLC 上のデータを比較する
      # 戻り値: { match: true/false, total: N, mismatches: [{addr:, expected:, actual:}] }
      def verify_image(image)
        # write_image と同じ正規化を通してから比較する
        # (正規化しないと STATUS が必ず不一致になる)
        image = normalize_image(image)
        mismatches = []
        runs = group_consecutive(image)

        runs.each do |start_addr, expected_values|
          actual_values = @adapter.read_words(start_addr, expected_values.size)
          expected_values.each_with_index do |expected, i|
            actual = actual_values[i]
            if actual != expected
              mismatches << { addr: start_addr + i, expected: expected, actual: actual }
            end
          end
        end

        { match: mismatches.empty?, total: image.size, mismatches: mismatches }
      end

      # VM リセット要求 (PLC 側の vm_init で処理される)
      def request_reset
        @adapter.write_word(layout.reset_req_addr, 1)
      end

      private

      # PLC に書き込む形へイメージを正規化する
      # load 時は STATUS=STOPPED にする (run で明示的に開始するため)
      def normalize_image(image)
        image = image.dup
        image[layout.status_addr] = VM_STOPPED
        image
      end

      # {addr => val} を連続するアドレスのグループに分割
      # [[start_addr, [val1, val2, ...]], ...]
      def group_consecutive(image)
        return [] if image.empty?

        sorted = image.sort_by { |addr, _| addr }
        runs = []
        current_start = sorted[0][0]
        current_values = [sorted[0][1]]

        sorted[1..].each do |addr, val|
          if addr == current_start + current_values.size
            current_values << val
          else
            runs << [current_start, current_values]
            current_start = addr
            current_values = [val]
          end
        end
        runs << [current_start, current_values]
        runs
      end
    end
  end
end
