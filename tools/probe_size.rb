# frozen_string_literal: true

# 大きさだけを見るプローブを書き出す
#
# **ST プログラム 1 本に何文字入るか**を確かめるためのものです。faRuby の VM は
# コードだけで 89,195 文字あり、いちばん大きい群が 39,266 文字です。そこが
# 入るかどうかで分割の仕方が決まります。
#
# 中身は D310 を数え上げるだけで、最後に目印を書きます。**変換が通って目印が
# 入っていれば、その大きさは入る**ということです。
#
# 使い方: ruby tools/probe_size.rb

DIR = File.expand_path("../plc/mitsubishi/probe", __dir__)

# [名前, おおよその文字数, 目印の値]
SIZES = [
  ["probe_03a_size_08k.st",  8_000,  8],
  ["probe_03b_size_40k.st", 40_000, 40],
  ["probe_03c_size_90k.st", 90_000, 90],
].freeze

MARKER = "D304"   # 03a → 8、03b → 40、03c → 90

SIZES.each do |name, target, marker|
  body = +"(* faRuby probe 3: 大きさの確認。約 #{target} 文字。README.md *)\n"
  body << "D310 := 0;\n"
  body << "D310 := D310 + 1;\n" while body.bytesize < target - 40
  body << "#{MARKER} := #{marker};\n"

  path = File.join(DIR, name)
  File.write(path, body, encoding: "utf-8")
  puts format("%-26s %7d 文字  %5d 行", name, body.bytesize, body.lines.size)
end

puts ""
puts "小さい方から順に ST プログラムを作って貼り、変換してください。"
puts "通らなくなったところが上限です。#{MARKER} を読むとどれが動いたか分かります。"
