# frozen_string_literal: true

# メモリ転送
# PlcCodegen#memory_image の Hash を PLC に効率的に書き込み、
# PLC から VM 状態やレジスタを読み出します。

require_relative "../memory_map"
require_relative "plc_adapters/base"

module MrubycOnPlc
  module Console
    class MemoryTransfer
      include MemoryMap

      STATUS_LABELS = {
        VM_STOPPED => "停止",
        VM_RUNNING => "実行中",
        VM_FINISHED => "完了",
        VM_ERROR => "エラー",
      }.freeze

      def initialize(adapter)
        @adapter = adapter
      end

      # memory_image Hash を PLC に書き込む
      # 連続アドレスをグループ化して一括転送する
      def write_image(image)
        # load 時は STATUS=STOPPED に上書き (run で明示的に開始)
        image = image.dup
        image[STATUS_ADDR] = VM_STOPPED

        runs = group_consecutive(image)
        total = 0
        runs.each do |start_addr, values|
          @adapter.write_words(start_addr, values)
          total += values.size
        end
        total
      end

      # VM 状態を PLC から読み出す
      def read_vm_state
        words = @adapter.read_words(VM_STATE_BASE, 14)
        {
          pc:              words[PC_ADDR],
          status:          words[STATUS_ADDR],
          status_label:    STATUS_LABELS[words[STATUS_ADDR]] || "不明(#{words[STATUS_ADDR]})",
          error:           words[ERROR_ADDR],
          step_count:      words[STEP_COUNT_ADDR] | (words[STEP_COUNT_ADDR + 1] << 16),
          steps_per_cycle: words[STEPS_PER_CYCLE],
          current_opcode:  words[CURRENT_OPCODE],
          operand_a:       words[OPERAND_A],
          operand_b:       words[OPERAND_B],
          operand_c:       words[OPERAND_C],
          bytecode_len:    words[BYTECODE_LEN_ADDR],
          nregs:           words[NREGS_ADDR],
          nlocals:         words[NLOCALS_ADDR],
          reset_req:       words[RESET_REQ_ADDR],
        }
      end

      # レジスタファイルを PLC から読み出す
      def read_registers(nregs = nil, nlocals = nil)
        unless nregs
          meta = @adapter.read_words(NREGS_ADDR, 2)
          nregs = meta[0]
          nlocals = meta[1]
        end
        nregs = [nregs, MAX_REGS].min
        nlocals ||= 0

        words = @adapter.read_words(REG_FILE_BASE, nregs * 2)
        regs = []
        nregs.times do |i|
          lo = words[i * 2] & 0xFFFF
          hi = words[i * 2 + 1] & 0xFFFF
          val = (hi << 16) | lo
          val -= 0x1_0000_0000 if val >= 0x8000_0000

          label = if i == 0
                    "self"
                  elsif i < nlocals
                    "local"
                  else
                    "temp"
                  end
          regs << { index: i, value: val, label: label }
        end
        regs
      end

      # VM STATUS を書き込む
      def write_status(value)
        @adapter.write_word(STATUS_ADDR, value)
      end

      # メモリイメージと PLC 上のデータを比較する
      # 戻り値: { match: true/false, total: N, mismatches: [{addr:, expected:, actual:}] }
      def verify_image(image)
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
        @adapter.write_word(RESET_REQ_ADDR, 1)
      end

      private

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
