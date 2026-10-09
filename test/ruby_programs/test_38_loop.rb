# loop
#
# 対象機種: KV-5000, KV-X500
#
# `loop` は `OP_SSENDB` (self への呼び出し) で、`3.times` の `OP_SENDB` とは
# 別命令です。self をレシーバ位置に置いてから `OP_SENDB` の枝へ落とす前処理
# として入れてあります。
#
# **上限がありません。** `times` / `upto` / `each` は反復フレームの「上限」と
# 比べて終わりますが、`loop` は種別で比較を飛ばすので `break` でしか終わり
# ません。上限を 2147483647 にする手は採っていません (何日か回すと終わって
# しまい、年単位で動く PLC に合わないため)。
#
# **ブロックに値は渡しません。** Ruby の `loop { |i| }` も `i` は `nil` です。
#
# R[0] がトップレベルの self (main) であることも併せて確かめます。mruby は
# `OP_LOADSELF` を書かずに R[0] が self である前提で呼び出すので、ここが
# 空だと `loop` がレシーバの型検査で弾かれます。
#
# 期待値:
#   $DM1020 = 5      break で抜けた回数
#   $DM1021 = 1      ブロックに渡る値が無い (偽のまま)
#   $DM1022 = 4      メソッドの中の loop
#   $DM1023 = 3      loop の中の times (外側のローカルに届く)
#   $DM1024 = 7      break の値が呼び出しの値になる
#
# 実機でのみ意味を持つ検証。

n = 0
loop do
  n = n + 1
  break if n >= 5
end
$DM1020 = n

got = 1
loop do |i|
  got = 0 if i
  break
end
$DM1021 = got

def count
  m = 0
  loop do
    m = m + 1
    break if m >= 4
  end
  m
end
$DM1022 = count

total = 0
loop do
  3.times do |i|
    total = total + i
  end
  break
end
$DM1023 = total

v = loop do
  break 7
end
$DM1024 = v
