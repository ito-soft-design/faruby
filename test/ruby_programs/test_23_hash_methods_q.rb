# ハッシュのメソッド
#
# 対象機種: Q
#
# **キーエンス版から機種名だけを置き換えたものです** (`DM` → `D`、`MR` → `M`)。
# アドレスはそのままで、faRuby の D4000-D5999 とも GX Works2 が一時変数に使う
# D6144 以降とも重なりません。
#
# size / length は組の数。鍵の配列の見出しから読む。
# key? は鍵の配列の線形走査で、一致は型と値の両方。
# keys / values は Ruby と同じく新しい配列を返すため、**プールを 1 スロット
# 使う**。ループの中で呼び続けると使い切る。配列リテラルと同じ制約。
#
# 期待値:
#   $D760 = 3      size
#   $D761 = 3      length
#   $D762 = 0      空ハッシュの size
#   $D763 = 1      key? が真
#   $D764 = 1      key? が偽
#   $D765 = 3      keys の要素数
#   $D766 = 1      values[0]
#   $D767 = 3      values[2]
#   $D768 = 1      整数の鍵 keys[0]
#   $D769 = 2      整数の鍵 keys[1]
#   $D770 = 3      keys は新しい配列なので足せる
#   $D771 = 2      足してもハッシュは変わらない
#   $D772 = 4      鍵を足した後の size
#   $D773 = 1      足した鍵の key?
#   $D774 = 4      足した後の values の最後
#   $D775 = 0      空ハッシュの keys
#   $D776 = 4      ブロックの中から size
#
# 実機でのみ意味を持つ検証。
#
# プールは 16 スロットで、ハッシュ 1 つが 2 つ、keys / values が 1 つずつ
# 使います。行を増やすときは残りに気をつけてください。

h = { a: 1, b: 2, c: 3 }
$D760 = h.size
$D761 = h.length

e = {}
$D762 = e.size

$D763 = 0
if h.key?(:b)
  $D763 = 1
end

$D764 = 0
if !h.key?(:z)
  $D764 = 1
end

k = h.keys
$D765 = k.length

v = h.values
$D766 = v[0]
$D767 = v[2]

g = { 1 => 10, 2 => 20 }
gk = g.keys
$D768 = gk[0]
$D769 = gk[1]

# keys が返すのは新しい配列。足してもハッシュ側は変わらない
gk << 99
$D770 = gk.length
$D771 = g.size

h[:d] = 4
$D772 = h.size
$D773 = 0
if h.key?(:d)
  $D773 = 1
end
hv = h.values
$D774 = hv[3]

ek = e.keys
$D775 = ek.length

2.times do
  $D776 = h.size
end
