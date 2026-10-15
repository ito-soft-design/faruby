# test_40_device_map.rb の割り付け表 (キーエンス)
#
# **これは PLC に送るプログラムではありません。** ホスト側で読むだけの表で、
# 読むときに本当に Ruby として実行します。

FaRuby.devices do
  map "motor", "MR101"      # ビットデバイス
  map "count", "DM1040"     # ワードデバイス
  map "speed", "DM1041L"    # 割り付け先に幅が付いている (DM1041 と DM1042)

  # **連番の配線は繰り返しで書ける。** これが Ruby にした値打ち
  4.times { |i| map "in_#{i}", "DM#{1045 + i}" }
end
