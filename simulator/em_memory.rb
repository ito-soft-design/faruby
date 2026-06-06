# frozen_string_literal: true

# EM レジスタシミュレーション
# Keyence PLC の EM デバイスメモリを Ruby でシミュレートします。

module MrubycOnPlc
  class EmMemory
    SIZE = 65536  # EM0 ~ EM65535

    def initialize
      @mem = Array.new(SIZE, 0)
    end

    # 16ビット符号なし読み取り (.U 相当)
    def read_u16(addr)
      @mem[addr] & 0xFFFF
    end

    # 16ビット符号なし書き込み
    def write_u16(addr, val)
      @mem[addr] = val & 0xFFFF
    end

    # 32ビット符号付き読み取り (.L 相当)
    # Keyence の .L は連続する2ワードを使用
    # 下位ワードが addr、上位ワードが addr+1
    def read_s32(addr)
      lo = @mem[addr] & 0xFFFF
      hi = @mem[addr + 1] & 0xFFFF
      val = (hi << 16) | lo
      val -= 0x1_0000_0000 if val >= 0x8000_0000
      val
    end

    # 32ビット符号付き書き込み (.L 相当)
    def write_s32(addr, val)
      val = val.to_i
      # 負数の場合は2の補数に変換
      val += 0x1_0000_0000 if val < 0
      @mem[addr] = val & 0xFFFF
      @mem[addr + 1] = (val >> 16) & 0xFFFF
    end

    # メモリイメージを一括ロード
    def load_image(image)
      image.each do |addr, val|
        @mem[addr] = val & 0xFFFF
      end
    end

    # デバッグ用: 指定範囲のメモリダンプ
    def dump(start_addr, count)
      (start_addr...(start_addr + count)).each do |addr|
        puts format("  EM%d = %d (0x%04x)", addr, @mem[addr], @mem[addr])
      end
    end
  end
end
