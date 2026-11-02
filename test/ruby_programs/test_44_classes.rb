# クラス
#
# 対象機種: KV-5000, KV-X500
#
# **メソッド表はクラス × 名前です。** 名前だけで引いていた表に行を足し、
# 0 行目を `main` にしました。レシーバのクラスで行が決まります。
#
# **オブジェクトは見出しのクラス番号を持ちます。** 値は *スロット + 1* です。
# 0 を `main` に使っているので、そのままだとプールの 0 番目と区別できません。
#
# **ここで見たいのは行の選び方です。** 同じ名前のメソッドを `main` と
# クラスの両方に置いてあります。0 行目だけを引く古い `OP_SEND` が入って
# いると、`a.value` が `main` の方を返して**エラーにならずに通ります** —
# 実際に KV-5000 で取り込み漏れがこの形で残っていました。
#
# **配列も文字列も使いません。** MELSEC Q は容量が足りず 3 つの型を外して
# いますが、クラスは載っています (tools/features.rb)。ここを飛ばさずに
# 走らせたいので、整数だけで書いてあります。
#
# 期待値:
#   $DM1150 = 3        initialize が引数を受け取った
#   $DM1151 = 8        2 つ目のオブジェクトは別の @n
#   $DM1152 = 11       足せる (3 + 8)
#   $DM1153 = 4        @n を書き替えられる
#   $DM1154 = 8        書き替えても相手の @n は動かない
#   $DM1155 = 99       main の同名メソッドは別の行
#   $DM1156 = 5        受け取らずに続けて呼べる
#   $DM1157 = 12       メソッドの中から self のメソッドを呼べる
#
# 実機でのみ意味を持つ検証。

class Counter
  def initialize(n)
    @n = n
  end

  def value
    @n
  end

  def bump
    @n = @n + 1
    @n
  end

  def twice
    value + value
  end
end

# **同じ名前を main にも置きます。** 行の選び方が崩れたらここに落ちる
def value
  99
end

a = Counter.new(3)
b = Counter.new(8)

$DM1150 = a.value
$DM1151 = b.value
$DM1152 = a.value + b.value

$DM1153 = a.bump
$DM1154 = b.value

$DM1155 = value

$DM1156 = Counter.new(5).value
$DM1157 = Counter.new(6).twice
