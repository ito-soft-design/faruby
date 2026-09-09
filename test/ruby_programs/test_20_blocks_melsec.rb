# ブロックと反復
#
# 対象機種: Q, iQ-R
#
# **キーエンス版から機種名だけを置き換えたものです** (`DM` → `D`、`MR` → `M`)。
# アドレスはそのままで、faRuby の D4000-D5999 とも GX Works2 が一時変数に使う
# D6144 以降とも重なりません。
#
# 3.times do |i| ... end は OP_SENDB だが、繰り返すのは Integer#times の側。
# VM は再帰できないため、反復フレームに「今何回目か」と「上限」を持たせ、
# ブロックの OP_RETURN で次の回に入り直す。
#
# ブロックは外側のローカル変数を読み書きする。ブロックの値には本体の irep と
# 定義元のフレームを持たせ、OP_GETUPVAR が鎖を段数ぶん辿る。
#
# 期待値:
#   $D690 = 3      3.times で 0+1+2
#   $D691 = 4      引数を書かないブロック (times は 1 個渡す)
#   $D692 = 0      0.times は 1 回も回らない
#   $D693 = 12     3.upto(5) で 3+4+5
#   $D694 = 0      5.upto(3) は 1 回も回らない
#   $D695 = 6      入れ子のブロックから 2 段外側を読む
#   $D696 = 3      break で打ち切る
#   $D697 = 6      メソッドの中のブロック
#   $D698 = 6      ブロックの中からメソッドを呼ぶ
#   $D699 = 15     反復の後も実行が続く
#
# 実機でのみ意味を持つ検証。

sum = 0
3.times do |i|
  sum = sum + i
end
$D690 = sum

n = 0
4.times do
  n = n + 1
end
$D691 = n

n = 0
0.times do
  n = n + 1
end
$D692 = n

sum = 0
3.upto(5) do |i|
  sum = sum + i
end
$D693 = sum

n = 0
5.upto(3) do
  n = n + 1
end
$D694 = n

s = 0
3.times do |i|
  2.times do |j|
    s = s + i
  end
end
$D695 = s

n = 0
10.times do |i|
  break if i == 3
  n = n + 1
end
$D696 = n

def total(m)
  t = 0
  m.times do |i|
    t = t + i
  end
  t
end
$D697 = total(4)

def twice(v)
  v * 2
end
s = 0
3.times do |i|
  s = s + twice(i)
end
$D698 = s

s = 0
3.times do |i|
  s = s + i
end
s = s + 12
$D699 = s
