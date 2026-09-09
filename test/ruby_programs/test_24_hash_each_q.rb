# ハッシュの each
#
# 対象機種: Q
#
# **キーエンス版から機種名だけを置き換えたものです** (`DM` → `D`、`MR` → `M`)。
# アドレスはそのままで、faRuby の D4000-D5999 とも GX Works2 が一時変数に使う
# D6144 以降とも重なりません。
#
# ブロックに引数を 2 つ渡す唯一の経路。反復フレームの種別で分け、
# 鍵を R[1]、値を R[2] に置く。
#
# **h.each { |k| } は Ruby と違います。** Ruby は [鍵, 値] の配列を渡しますが、
# faRuby は鍵だけを渡します。配列を毎回作るとプールを食い潰すためです。
#
# 期待値:
#   $D790 = 66     鍵と値の両方を受ける
#   $D791 = 6      引数 1 個なら鍵だけ
#   $D792 = 3      引数なしのブロックも回る
#   $D793 = 7      空ハッシュはブロックに入らない
#   $D794 = 11     break で打ち切る
#   $D795 = 3      each はレシーバを返す
#   $D796 = 66     ブロックの中でメソッドを呼んでも引数が消えない
#   $D797 = 3      シンボルの鍵
#   $D798 = 6      配列の each (回帰)
#   $D799 = 18     配列の each の中でハッシュの each
#
# 実機でのみ意味を持つ検証。

def zero
  0
end

h = { 1 => 10, 2 => 20, 3 => 30 }

t = 0
h.each do |k, v|
  t = t + k + v
end
$D790 = t

t = 0
h.each do |k|
  t = t + k
end
$D791 = t

t = 0
h.each do
  t = t + 1
end
$D792 = t

e = {}
t = 7
e.each do |k, v|
  t = 0
end
$D793 = t

t = 0
h.each do |k, v|
  t = t + k + v
  break
end
$D794 = t

x = h.each do |k, v|
  t = 0
end
$D795 = x.size

# ブロックの中でユーザー定義メソッドを呼ぶと call_argc が上書きされる。
# 引数の数を毎回書き直していないと、次の回で鍵と値が消える
t = 0
h.each do |k, v|
  zero
  t = t + k + v
end
$D796 = t

s = { a: 1, b: 2 }
t = 0
s.each do |k, v|
  t = t + v
end
$D797 = t

a = [1, 2, 3]
t = 0
a.each do |v|
  t = t + v
end
$D798 = t

# 配列の each の中でハッシュの each。種別の違うフレームが 2 段積まれる
t = 0
a.each do |v|
  h.each do |k, w|
    t = t + k
  end
end
$D799 = t
