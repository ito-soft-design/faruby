# ブロックと反復
#
# 対象機種: Q
#
# **出力先は D3000 台**です。faRuby 自身が D4000-D5999、GX Works2 の自動割付が
# D6144 以降を使うので、そこから離しています。
#
# 3.times do |i| ... end は OP_SENDB だが、繰り返すのは Integer#times の側。
# VM は再帰できないため、反復フレームに「今何回目か」と「上限」を持たせ、
# ブロックの OP_RETURN で次の回に入り直す。
#
# ブロックは外側のローカル変数を読み書きする。ブロックの値には本体の irep と
# 定義元のフレームを持たせ、OP_GETUPVAR が鎖を段数ぶん辿る。
#
# 期待値:
#   $D3690 = 3      3.times で 0+1+2
#   $D3691 = 4      引数を書かないブロック (times は 1 個渡す)
#   $D3692 = 0      0.times は 1 回も回らない
#   $D3693 = 12     3.upto(5) で 3+4+5
#   $D3694 = 0      5.upto(3) は 1 回も回らない
#   $D3695 = 6      入れ子のブロックから 2 段外側を読む
#   $D3696 = 3      break で打ち切る
#   $D3697 = 6      メソッドの中のブロック
#   $D3698 = 6      ブロックの中からメソッドを呼ぶ
#   $D3699 = 15     反復の後も実行が続く
#
# 実機でのみ意味を持つ検証。

sum = 0
3.times do |i|
  sum = sum + i
end
$D3690 = sum

n = 0
4.times do
  n = n + 1
end
$D3691 = n

n = 0
0.times do
  n = n + 1
end
$D3692 = n

sum = 0
3.upto(5) do |i|
  sum = sum + i
end
$D3693 = sum

n = 0
5.upto(3) do
  n = n + 1
end
$D3694 = n

s = 0
3.times do |i|
  2.times do |j|
    s = s + i
  end
end
$D3695 = s

n = 0
10.times do |i|
  break if i == 3
  n = n + 1
end
$D3696 = n

def total(m)
  t = 0
  m.times do |i|
    t = t + i
  end
  t
end
$D3697 = total(4)

def twice(v)
  v * 2
end
s = 0
3.times do |i|
  s = s + twice(i)
end
$D3698 = s

s = 0
3.times do |i|
  s = s + i
end
s = s + 12
$D3699 = s
