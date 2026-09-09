# メソッドの定義と呼び出し
#
# 対象機種: Q
#
# **出力先は D3000 台**です。faRuby 自身が D4000-D5999、GX Works2 の自動割付が
# D6144 以降を使うので、そこから離しています。
#
# def の本体は子 irep になる。呼び出しはフレームを積み、レジスタ窓を R[a] まで
# ずらして移る。呼ばれた側の R[0] は呼んだ側の R[a] と同じ場所なので、
# 戻り値のコピーは要らない。
#
# 期待値:
#   $D3670 = 7      引数なし
#   $D3671 = 5      引数2個
#   $D3672 = 10     1つの式で二度呼ぶ (レジスタ窓が戻らないと壊れる)
#   $D3673 = 12     入れ子の呼び出し
#   $D3674 = 120    再帰 (フレームとレジスタ窓が積み上がる)
#   $D3675 = 0      メソッド途中の return
#   $D3676 = 14     メソッド内のローカル変数
#   $D3677 = 99     メソッド内からのデバイス書き込み
#   $D3678 = 8      グローバル変数は irep をまたいで同じスロット
#   $D3679 = 3      組み込みメソッドとの併用
#
# 実機でのみ意味を持つ検証。

def seven
  7
end

def add(a, b)
  a + b
end

def twice(v)
  v * 2
end

def quad(v)
  twice(twice(v))
end

def fact(n)
  if n <= 1
    1
  else
    n * fact(n - 1)
  end
end

def clamp(v)
  return 0 if v < 0
  v * 2
end

def calc(v)
  t = v * 2
  u = t + 4
  u
end

def store
  $D3677 = 99
end

def bump
  $total = $total + 5
end

def neg(v)
  0 - v
end

$D3670 = seven
$D3671 = add(2, 3)
$D3672 = twice(2) + twice(3)
$D3673 = quad(3)
$D3674 = fact(5)
$D3675 = clamp(-3)
$D3676 = calc(5)

store

$total = 3
bump
$D3678 = $total

a = neg(3)
$D3679 = a.abs
