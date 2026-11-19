# frozen_string_literal: true

# Intel HEX パーサー
#
# Intel HEX ファイルをパースして、アドレス => バイト のハッシュ (メモリイメージ) を返す。
# BTK (ND8080 書き込みフォーマット) への変換も行う。

module FaRuby
  module IntelHex
    # Intel HEX をパースしてメモリイメージ (Hash: addr => byte) を返す
    def self.parse(hex_text)
      mem = {}
      hex_text.each_line do |line|
        line = line.strip
        next if line.empty?
        next unless line.start_with?(":")
        len = line[1, 2].to_i(16)
        addr = line[3, 4].to_i(16)
        type = line[7, 2].to_i(16)
        next unless type == 0x00 # データレコードのみ
        len.times do |i|
          mem[addr + i] = line[9 + i * 2, 2].to_i(16)
        end
      end
      mem
    end

    # メモリイメージをファイルからパースする
    def self.parse_file(path)
      parse(File.read(path))
    end

    # メモリイメージを連続領域に分割する
    #
    # exclude_ranges: 除外するアドレス範囲の配列 [[start, end], ...]
    #   除外範囲に含まれるアドレスは出力しない。除外範囲で領域が分断される。
    #
    # 戻り値: [[start_addr, bytes_array], ...] の配列
    def self.split_regions(mem, exclude_ranges: [])
      return [] if mem.empty?

      excluded = Set.new
      exclude_ranges.each do |s, e|
        (s..e).each { |a| excluded.add(a) }
      end

      regions = []
      sorted = mem.keys.sort
      chunk_start = nil
      chunk = []

      sorted.each do |addr|
        if excluded.include?(addr)
          # 除外範囲: 現在のチャンクを閉じる
          unless chunk.empty?
            regions << [chunk_start, chunk]
            chunk = []
            chunk_start = nil
          end
          next
        end

        if chunk.empty?
          chunk_start = addr
          chunk = [mem[addr]]
        elsif addr == chunk_start + chunk.size
          chunk << mem[addr]
        else
          # ギャップ: ゼロで埋めるか分割するか
          gap = addr - (chunk_start + chunk.size)
          if gap <= 256
            # 小さいギャップはゼロで埋める
            gap.times { chunk << 0 }
            chunk << mem[addr]
          else
            # 大きいギャップは分割
            regions << [chunk_start, chunk]
            chunk_start = addr
            chunk = [mem[addr]]
          end
        end
      end
      regions << [chunk_start, chunk] unless chunk.empty?
      regions
    end

    # BTK 形式のバイナリ文字列を生成する
    #
    # BTK: 開始アドレス (2B big-endian) + 終了アドレス (2B big-endian) + データ
    def self.to_btk(start_addr, bytes)
      end_addr = start_addr + bytes.size - 1
      [start_addr, end_addr].pack("nn") + bytes.pack("C*")
    end

    # メモリイメージから ND8080 用の BTK データを生成する
    #
    # ND8080 の割り込みベクタ (0x83C7-0x83F7) を除外して領域を分割し、
    # 各領域の BTK バイナリを返す。
    #
    # 戻り値: [[start_addr, end_addr, btk_binary], ...]
    def self.to_nd8080_btks(mem)
      regions = split_regions(mem, exclude_ranges: [[0x83C7, 0x83F7]])
      regions.map do |start_addr, bytes|
        end_addr = start_addr + bytes.size - 1
        btk = to_btk(start_addr, bytes)
        [start_addr, end_addr, btk]
      end
    end
  end
end
