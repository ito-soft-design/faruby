# ハッシュのメソッド
#
# 対象機種: KV-5000, KV-X500
#
# size / length は組の数。鍵の配列の見出しから読む。
# key? は鍵の配列の線形走査で、一致は型と値の両方。
# keys / values は Ruby と同じく新しい配列を返すため、**プールを 1 スロット
# 使う**。ループの中で呼び続けると使い切る。配列リテラルと同じ制約。
#
# 期待値:
#   $DM760 = 3      size
#   $DM761 = 3      length
#   $DM762 = 0      空ハッシュの size
#   $DM763 = 1      key? が真
#   $DM764 = 1      key? が偽
#   $DM765 = 3      keys の要素数
#   $DM766 = 1      values[0]
#   $DM767 = 3      values[2]
#   $DM768 = 1      整数の鍵 keys[0]
#   $DM769 = 2      整数の鍵 keys[1]
#   $DM770 = 3      keys は新しい配列なので足せる
#   $DM771 = 2      足してもハッシュは変わらない
#   $DM772 = 4      鍵を足した後の size
#   $DM773 = 1      足した鍵の key?
#   $DM774 = 4      足した後の values の最後
#   $DM775 = 0      空ハッシュの keys
#   $DM776 = 4      ブロックの中から size
#
# 実機でのみ意味を持つ検証。
#
# プールは 16 スロットで、ハッシュ 1 つが 2 つ、keys / values が 1 つずつ
# 使います。行を増やすときは残りに気をつけてください。

h = { a: 1, b: 2, c: 3 }
$DM760 = h.size
$DM761 = h.length

e = {}
$DM762 = e.size

$DM763 = 0
if h.key?(:b)
  $DM763 = 1
end

$DM764 = 0
if !h.key?(:z)
  $DM764 = 1
end

k = h.keys
$DM765 = k.length

v = h.values
$DM766 = v[0]
$DM767 = v[2]

g = { 1 => 10, 2 => 20 }
gk = g.keys
$DM768 = gk[0]
$DM769 = gk[1]

# keys が返すのは新しい配列。足してもハッシュ側は変わらない
gk << 99
$DM770 = gk.length
$DM771 = g.size

h[:d] = 4
$DM772 = h.size
$DM773 = 0
if h.key?(:d)
  $DM773 = 1
end
hv = h.values
$DM774 = hv[3]

ek = e.keys
$DM775 = ek.length

2.times do
  $DM776 = h.size
end
