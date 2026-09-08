# frozen_string_literal: true

# プローブの結果を読む
#
# **機種依存の項目は、確認したい式を並べたプログラムを PLC へ転送し、
# 結果をホストから読んで確かめます** (doc/differences.md)。これはその
# 読み取り側です。faRuby の VM とは無関係で、デバイスを直接読むだけです。
#
# 使い方:
#   ruby tools/probe_read.rb <host> [port]
#
# 読む場所は plc/mitsubishi/probe/*.st の見出しに書いてあります。

require "plc_access"

host = ARGV[0] or abort "使い方: ruby tools/probe_read.rb <host> [port] [プローブ番号]"
port = (ARGV[1] || 5010).to_i
number = (ARGV[2] || 1).to_i

plc = PlcAccess::Protocol::Mitsubishi::McProtocol.new(host: host, port: port)

# [ラベル, デバイス, 読み方, 期待値]
PROBES = {
  1 => [
    ["1  素の代入",              "D100", :s16, 1],
    ["2  インデックス修飾 (書き)", "D122", :s16, 2],
    ["3  インデックス修飾 (読み)", "D124", :s16, 3],
    ["4  Z を式で作る",           "D130", :s16, 4],
    ["5  32 ビット",              "D140", :s32, 100_000],
    ["6  32 ビットの修飾",         "D144", :s32, 200_000],
    ["7  実数",                  "D150", :f32, 2.5],
    ["8  実数 → 整数 (-2.7)",     "D154", :s16, -3],
    ["9  整数の割り算 (-7 / 2)",   "D156", :s16, -3],
    ["10 入れ子 FOR の EXIT",     "D160", :s16, 5],
  ],
  2 => [
    ["11b 32 ビットの足し算",      "D200", :s32, 300_000],
    ["11c 素の式 (16 ビットの罠)",  "D206", :s16, nil],
    ["12 32 ビットの修飾つき読み",  "D204", :s32, 100_000],
    ["13 32 ビットの比較",         "D210", :s16, 1],
    ["14 実数 → 整数 (-2.2)",     "D212", :s16, nil],
    ["15 実数 → 整数 (2.7)",      "D214", :s16, nil],
    ["16 ラベル配列 (DINT)",       "D220", :s32, 123_456],
    ["17 ラベル配列で 32 ビット計算", "D222", :s32, 246_912],
    ["18 ラベル配列 (INT)",        "D230", :s16, 7],
    ["19 ラベル配列 (REAL)",       "D240", :f32, 1.5],
    ["20 ビットデバイス M",        "D250", :s16, 1],
    ["21 ワードのビット指定 D0.0",  "D252", :s16, 1],
    ["23 読んで直して書く",         "D254", :s16, 1],
    ["33 型を重ねる (2.5 の中身)",   "D224", :s32, 1_075_838_976],
    ["34 REAL_TO_INT(-2.7)",      "D231", :s16, nil],
    ["34 REAL_TO_INT(2.7)",       "D232", :s16, nil],
    ["34 REAL_TO_INT(-2.2)",      "D233", :s16, nil],
    ["36 DINT の比較",             "D226", :s32, 1],
  ],
  3 => [
    # 8 なら 8k まで、40 なら 40k まで、90 なら 90k まで入った
    ["3  入った大きさ",            "D304", :s16, nil],
  ],
  4 => [
    ["24 ZR に書く",              "D270", :s16, 24],
    ["25 ZR を 32 ビットで",       "D272", :s32, 300_000],
    ["26 ZR のインデックス修飾",    "D274", :s16, 26],
    ["27 R (バンク付き)",          "D276", :s16, 27],
    ["28 ZR4999 まで届くか",       "D278", :s16, 28],
  ],
}.freeze

def read(plc, device, kind)
  case kind
  when :s16 then to_signed(plc[device], 16)
  when :s32 then to_signed(read_words(plc, device, 2).reverse.inject { |h, l| (h << 16) | l }, 32)
  when :f32 then [read_words(plc, device, 2).reverse.inject { |h, l| (h << 16) | l }].pack("N").unpack1("g")
  end
rescue StandardError => e
  "読めません (#{e.class})"
end

def read_words(plc, device, count)
  suffix = device[/\A[A-Z]+/]
  number = device[/\d+\z/].to_i
  (0...count).map { |i| plc["#{suffix}#{number + i}"] }
end

def to_signed(value, bits)
  limit = 1 << (bits - 1)
  value >= limit ? value - (limit * 2) : value
end

items = PROBES[number] or abort "プローブ #{number} は知りません (#{PROBES.keys.join(', ')})"

puts "接続先: #{host}:#{port}  プローブ #{number}"
puts ""
items.each do |label, device, kind, expected|
  actual = read(plc, device, kind)
  mark =
    if expected.nil?          then "  "        # 期待値を決めるための項目
    elsif actual == expected  then "OK"
    else                           "NG"
    end
  detail = expected.nil? || actual == expected ? "" : "  (期待 #{expected})"
  puts format("  %-2s %-26s %-6s = %s%s", mark, label, device, actual, detail)
end
