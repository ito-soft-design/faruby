# loop
#
# 対象機種: Q, iQ-R
#
# **キーエンス版から機種名だけを置き換えたものです** (`DM` → `D`)。
#
# `loop` は `OP_SSENDB` (self への呼び出し) で、`3.times` の `OP_SENDB` とは
# 別命令です。self をレシーバ位置に置いてから `OP_SENDB` の枝へ落とす前置き
# として入れてあります。
#
# **上限がありません。** 種別で比較を飛ばすので `break` でしか終わりません。
# **ブロックに値は渡しません。** Ruby の `loop { |i| }` も `i` は `nil` です。
#
# 期待値:
#   $D1020 = 5      break で抜けた回数
#   $D1021 = 1      ブロックに渡る値が無い (偽のまま)
#   $D1022 = 4      メソッドの中の loop
#   $D1023 = 3      loop の中の times (外側のローカルに届く)
#   $D1024 = 7      break の値が呼び出しの値になる
#
# 実機でのみ意味を持つ検証。

n = 0
loop do
  n = n + 1
  break if n >= 5
end
$D1020 = n

got = 1
loop do |i|
  got = 0 if i
  break
end
$D1021 = got

def count
  m = 0
  loop do
    m = m + 1
    break if m >= 4
  end
  m
end
$D1022 = count

total = 0
loop do
  3.times do |i|
    total = total + i
  end
  break
end
$D1023 = total

v = loop do
  break 7
end
$D1024 = v
