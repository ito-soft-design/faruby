# メソッドの定義と呼び出し
#
# 対象機種: KV-5000, KV-X500
#
# def の本体は子 irep になる。呼び出しはフレームを積み、レジスタ窓を R[a] まで
# ずらして移る。呼ばれた側の R[0] は呼んだ側の R[a] と同じ場所なので、
# 戻り値のコピーは要らない。
#
# 期待値:
#   $DM670 = 7      引数なし
#   $DM671 = 5      引数2個
#   $DM672 = 10     1つの式で二度呼ぶ (レジスタ窓が戻らないと壊れる)
#   $DM673 = 12     入れ子の呼び出し
#   $DM674 = 120    再帰 (フレームとレジスタ窓が積み上がる)
#   $DM675 = 0      メソッド途中の return
#   $DM676 = 14     メソッド内のローカル変数
#   $DM677 = 99     メソッド内からのデバイス書き込み
#   $DM678 = 8      グローバル変数は irep をまたいで同じスロット
#   $DM679 = 3      組み込みメソッドとの併用
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
  $DM677 = 99
end

def bump
  $total = $total + 5
end

def neg(v)
  0 - v
end

$DM670 = seven
$DM671 = add(2, 3)
$DM672 = twice(2) + twice(3)
$DM673 = quad(3)
$DM674 = fact(5)
$DM675 = clamp(-3)
$DM676 = calc(5)

store

$total = 3
bump
$DM678 = $total

a = neg(3)
$DM679 = a.abs
