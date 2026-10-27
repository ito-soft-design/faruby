# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../tools/vm_constants"
require_relative "../tools/device_syntax"
require_relative "../tools/device_map"
require_relative "../tools/device_set"

# デバイスの割り付け表
#
# **設備が変わってもプログラムを直さずに済むようにするものです。** デバイスを
# 抽象的な名前で書き、実デバイスへの割り付けを設定で持ちます。配線は設備ごとに
# 違い、連続している保証も無いので、範囲ではなく 1 点ずつ割り付けます。
#
# **実行時の費用はゼロです。** 種別と番号は実行時にシンボル表から引いていて、
# 生成スクリプトは名前を知りません。表の項目に割り付け先の種別と番号を入れれば、
# 実デバイスを直に書いたのと同じバイトコード・同じ速度になります。
class TestDeviceMap < Minitest::Test
  include FaRuby::VmConstants

  MAP = { "x0" => "MR100", "y0" => "DM200", "speed" => "DM300L" }.freeze

  def syntax(mapping = MAP, warn: false)
    FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.keyence,
                             mapping: mapping, warn_unmapped: warn)
  end

  def plain = FaRuby::DeviceSyntax.keyence

  # === 読み方 ===

  # **実デバイスを直に書いたのと見分けが付かないこと。** ここが同じなので
  # 抽象化しても生成物も速度も変わりません
  def test_a_mapped_name_reads_like_the_device_itself
    assert_equal plain.parse_symbol("$MR100"), syntax.parse_symbol("$x0")
    assert_equal plain.parse_symbol("$DM200"), syntax.parse_symbol("$y0")
  end

  # ビットデバイスへの割り付けは真偽値として読める形になる
  def test_a_name_mapped_to_a_bit_device_stays_a_bit
    parsed = syntax.parse_symbol("$x0")

    assert parsed[:bit], "ビットとして読めていない"
    assert_nil parsed[:access_type]
  end

  # === `@` でも引く ===
  #
  # **写して回す手順を書かずに済むようにするためです。** 表に載せた名前は
  # `@run_btn` と書いても実デバイスになるので、`read_inputs` /
  # `write_outputs` で `$` と `@` の間を写す必要がありません。

  def test_an_instance_variable_reads_the_mapped_device
    assert_equal plain.parse_symbol("$MR100"), syntax.parse_symbol("@x0")
    assert_equal plain.parse_symbol("$DM200"), syntax.parse_symbol("@y0")
  end

  # `$` と `@` でまったく同じものになる (枠も速度も同じ)
  def test_the_sigil_does_not_change_the_result
    assert_equal syntax.parse_symbol("$x0"), syntax.parse_symbol("@x0")
  end

  def test_the_width_suffix_works_on_an_instance_variable
    assert_equal ACCESS_L, syntax.parse_symbol("@y0L")[:access_type]
    assert_equal "DM", syntax.parse_symbol("@y0L")[:device_name]
  end

  # 表に無い `@` は今までどおり変数のまま
  def test_an_unmapped_instance_variable_is_not_a_device
    assert_nil syntax.parse_symbol("@timer1")
  end

  # **クラス変数は引きません。** 未対応なので、plc_codegen が止めます
  def test_a_class_variable_is_not_looked_up
    assert_nil syntax(MAP.merge("@x0" => "MR100")).parse_symbol("@@x0")
    assert_nil syntax.parse_symbol("@@x0")
  end

  # === 幅サフィックス ===

  # **名前を引いてから幅を付けます。** 逆にすると `$y0L` の `y0L` を
  # デバイス名として探してしまいます
  def test_the_width_suffix_applies_after_the_lookup
    assert_equal ACCESS_S, syntax.parse_symbol("$y0")[:access_type]
    assert_equal ACCESS_L, syntax.parse_symbol("$y0L")[:access_type]
    assert_equal ACCESS_D, syntax.parse_symbol("$y0_D")[:access_type]
    assert_equal "DM", syntax.parse_symbol("$y0L")[:device_name]
    assert_equal "200", syntax.parse_symbol("$y0L")[:address]
  end

  # 表に幅を書いておける (`speed: DM300L`)
  def test_the_target_can_carry_the_width
    assert_equal ACCESS_L, syntax.parse_symbol("$speed")[:access_type]
  end

  # 使う側の幅が表のものより優先する
  def test_the_use_site_width_wins
    assert_equal ACCESS_S, syntax.parse_symbol("$speedS")[:access_type]
  end

  # **表に書いた名前がそのまま勝ちます。** `x0L` という名前も作れる
  def test_an_exact_entry_beats_the_suffix_split
    mapping = MAP.merge("y0L" => "R500")
    parsed = syntax(mapping).parse_symbol("$y0L")

    assert_equal "R", parsed[:device_name], "表の y0L ではなく y0 + .L を引いている"
  end

  # === 表に無い名前 ===

  # **表は任意です。** 書かない設備も、表に無い名前も影響を受けません
  def test_names_outside_the_map_read_as_before
    assert_equal plain.parse_symbol("$DM500"), syntax.parse_symbol("$DM500")
    assert_nil syntax.parse_symbol("$total"), "汎用グローバルはデバイスにしない"
  end

  def test_an_empty_map_changes_nothing
    %w[$DM100 $MR400 $DM100L $B1F].each do |name|
      assert_equal plain.parse_symbol(name), syntax({}).parse_symbol(name), name
    end
    assert_nil syntax({}).parse_symbol("$total")
  end

  # === 設定の検査 ===

  # **表そのものを転送前に検査します。** 使っていない名前の書き間違いも、
  # 設定を読んだ時点で止まります
  def test_a_typo_in_the_target_stops_at_load_time
    error = assert_raises(FaRuby::CodegenError) { syntax({ "x0" => "ZZZ9" }) }

    assert_includes error.message, "ZZZ9"
    assert_includes error.message, "割り付け表"
  end

  # === 添字で引ける範囲 ===

  # **連続した範囲は添字で引けること。** 基点が 0 でないデバイス族になります
  #
  # `$DM[i]` は DM0 からですが、割り付けた名前なら `$regs[0]` を DM1100 から
  # 始められます。**VM に足すものはありません** — 添字はデバイス番号に
  # そのまま足されるので、種別と基点をシンボル表に入れるだけで済みます。
  def test_a_range_is_a_family_with_a_base
    entry = syntax({ "regs" => ["DM1100", 8] }).parse_symbol("$regs")

    assert entry[:family], "添字で引ける形になっていること"
    assert_equal 1100, entry[:z_offset]
    assert_equal 8, entry[:words]
  end

  # 幅は範囲にも書ける (割り付け先と使う側のどちらでも)
  def test_a_range_can_carry_a_width
    from_target = syntax({ "regs" => ["DM1100L", 8] }).parse_symbol("$regs")
    from_use    = syntax({ "regs" => ["DM1100", 8] }).parse_symbol("$regsL")

    assert_equal ACCESS_L, from_target[:access_type]
    assert_equal ACCESS_L, from_use[:access_type]
    assert_equal 8, from_use[:words]
  end

  # ビットデバイスの範囲も作れる。**番号の数え方はメーカーのもの**
  #
  # `MR100` は番号 16 なので、`$bits[15]` は番号 31 = `MR115` です。
  def test_a_range_of_bits_counts_the_way_its_vendor_counts
    entry = syntax({ "bits" => ["MR100", 16] }).parse_symbol("$bits")

    assert_equal 16, entry[:z_offset]
    assert_equal "MR115", "MR#{syntax.address_of('MR', entry[:z_offset] + 15)}"
  end

  # ワード数を書かなければ今までどおり 1 点 (添字は付かない)
  def test_without_a_count_it_stays_a_single_point
    entry = syntax({ "x0" => "MR100" }).parse_symbol("$x0")

    refute entry[:family], "1 点は族にしない"
    assert_nil entry[:words]
  end

  # ワード数の誤りは転送前に止める
  def test_a_bad_count_stops
    [0, -1, "いくつか", 1.5].each do |bad|
      assert_raises(FaRuby::CodegenError, "ワード数 #{bad.inspect}") do
        syntax({ "regs" => ["DM1100", bad] })
      end
    end
  end

  # **範囲の終わりがアドレスの上限を越えたら止める。** デバイス参照は
  # ベースアドレスを 1 ワードに詰めるので 65535 までです
  def test_a_range_past_the_end_of_the_address_space_stops
    syntax({ "regs" => ["DM65000", 536] })   # 65535 までは通る

    error = assert_raises(FaRuby::CodegenError) { syntax({ "regs" => ["DM65000", 537] }) }

    assert_includes error.message, "65536"
  end

  # **実デバイスの名前は割り付けられません。** 通すと `$DM100` の意味が
  # 設備ごとに変わり、読む人が追えなくなります
  def test_a_real_device_name_cannot_be_mapped
    assert_raises(FaRuby::CodegenError) { syntax({ "DM100" => "R0" }) }
    assert_raises(FaRuby::CodegenError) { syntax({ "MR400" => "R0" }) }
  end

  # 族の名前も同じ。`$DM[i]` の意味が変わってしまう
  def test_a_family_name_cannot_be_mapped
    assert_raises(FaRuby::CodegenError) { syntax({ "DM" => "R0" }) }
  end

  # 割り付け先が族だと番号が決まらない
  def test_the_target_cannot_be_a_family
    assert_raises(FaRuby::CodegenError) { syntax({ "x0" => "DM" }) }
  end

  # 割り付け先の種別と使い方が食い違う設定は転送前に弾く
  def test_a_use_that_does_not_fit_the_target_stops
    error = assert_raises(FaRuby::CodegenError) { syntax.parse_symbol("$x0T6") }

    assert_includes error.message, "MR100", "どの割り付けで起きたか分かること"
  end

  # === 警告 ===

  # 全部を抽象化したい設備で実デバイスの直書きを見つける
  def test_unmapped_names_are_remembered_when_asked
    s = syntax(MAP, warn: true)
    %w[$x0 $DM500 $R10 $total].each { |name| s.parse_symbol(name) }

    assert_equal ["$DM500", "$R10"], s.unmapped
  end

  def test_the_same_name_is_remembered_once
    s = syntax(MAP, warn: true)
    3.times { s.parse_symbol("$DM500") }

    assert_equal ["$DM500"], s.unmapped
  end

  # 既定では覚えない。**表を混ぜて使う設備では警告が邪魔になる**
  def test_nothing_is_remembered_by_default
    s = syntax
    s.parse_symbol("$DM500")

    assert_empty s.unmapped
    refute s.warn_unmapped?
  end

  # 抽象化していない設備では意味が無い
  def test_an_empty_map_remembers_nothing
    s = syntax({}, warn: true)
    s.parse_symbol("$DM500")

    assert_empty s.unmapped
    refute s.warn_unmapped?
  end

  # === 機種 ===

  # **番号の数え方は機種に付いて回ります。** 割り付け先の読み方も同じ
  # (キーエンスの MR400 は 64、三菱の M400 は 400)
  def test_the_target_is_numbered_the_way_its_vendor_counts
    keyence = FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.keyence, mapping: { "motor" => "MR400" })
    melsec  = FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.melsec,  mapping: { "motor" => "M400" })

    assert_equal 64, keyence.parse_symbol("$motor")[:z_offset]
    assert_equal 400, melsec.parse_symbol("$motor")[:z_offset]
  end

  # **使える名前は機種で違います。** 三菱には X / Y があるので `x0` は
  # 実デバイスで、割り付ける名前には使えません。キーエンスには無いので通ります。
  #
  # 同じ表を両方の機種で使うなら、どちらの実デバイスとも重ならない名前
  # (`in_0` のように区切りを入れる) にしてください。**設定を読んだ時点で
  # 止まるので、気づかないまま別のデバイスを指すことはありません。**
  def test_which_names_are_free_depends_on_the_vendor
    FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.keyence, mapping: { "x0" => "R0" })

    assert_raises(FaRuby::CodegenError) do
      FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.melsec, mapping: { "x0" => "R0" })
    end
    # 区切りを入れれば両方で通る
    %i[keyence melsec].each do |vendor|
      FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.send(vendor), mapping: { "in_0" => "R0" })
    end
  end
end

# 割り付け表のファイル
#
# **割り付けは PLC ではなくプログラムのものです。** 同じ PLC に別の
# プログラムを載せれば割り付けも変わるので、接続設定ではなくプログラムの
# 隣に置き、プログラムの先頭 1 行でどの表を使うかを書きます。
#
# 表は Ruby です。**読むときに本当に実行する**ので、連番の配線を繰り返しで
# 書けます。これが YAML にしなかった理由です。
class TestDeviceMapFile < Minitest::Test
  def with_program(program, table = nil, table_name: "line.devices.rb")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, table_name), table, encoding: "utf-8") if table
      path = File.join(dir, "line.rb")
      File.write(path, program, encoding: "utf-8")
      yield path
    end
  end

  # === 読み込み ===

  # **プログラムがどの表を使うかを指すこと**
  def test_a_program_points_at_its_table
    table = <<~RUBY
      FaRuby.devices do
        map "start", "R0"
        map "motor", "R500"
      end
    RUBY
    with_program("# devices: line.devices.rb\n$motor = $start\n", table) do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_equal({ "start" => "R0", "motor" => "R500" }, map.mapping)
      assert_equal 2, map.size
    end
  end

  # 書かないプログラムは空。**表は任意で、今までどおり実デバイスで書ける**
  def test_a_program_without_the_line_has_no_table
    with_program("$R500 = $R0\n") do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_empty map.mapping
      assert_predicate map, :empty?
      assert_nil map.path
      refute_predicate map, :warn_unmapped?
    end
  end

  # **Ruby にした値打ちはここです。** 連番の配線を手で並べずに済みます
  def test_a_table_can_generate_its_entries
    table = <<~'RUBY'
      FaRuby.devices do
        16.times { |i| map "in_#{i}", "R#{i}" }
        map "speed", "DM300L"
      end
    RUBY
    with_program("# devices: line.devices.rb\n", table) do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_equal 17, map.size
      assert_equal "R0", map.mapping["in_0"]
      assert_equal "R15", map.mapping["in_15"]
      assert_equal "DM300L", map.mapping["speed"]
    end
  end

  # ブロックを分けて書けること (入力と出力を離して書く)
  def test_two_blocks_add_up
    table = <<~RUBY
      FaRuby.devices { map "start", "R0" }
      FaRuby.devices { map "motor", "R500" }
    RUBY
    with_program("# devices: line.devices.rb\n", table) do |path|
      assert_equal 2, FaRuby::DeviceMap.for_program(path).size
    end
  end

  # **ワード数を渡せば添字で引ける範囲になること**
  def test_a_table_can_declare_a_range
    table = <<~'RUBY'
      FaRuby.devices do
        map "iai_regs", "D100", 8
        map "start",    "M0"
      end
    RUBY
    with_program("# devices: line.devices.rb\n", table) do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_equal ["D100", 8], map.mapping["iai_regs"]
      assert_equal "M0", map.mapping["start"]
    end
  end

  # 表を通らない直書きを知らせる指示も表に書く (設定を 2 箇所に分けない)
  def test_the_table_asks_for_the_warning
    table = <<~RUBY
      FaRuby.devices do
        warn_unmapped!
        map "start", "R0"
      end
    RUBY
    with_program("# devices: line.devices.rb\n", table) do |path|
      assert_predicate FaRuby::DeviceMap.for_program(path), :warn_unmapped?
    end
  end

  # **同じ表を 2 度読めること。** `require` だと 2 度目を黙って飛ばすので、
  # コンパイルし直したときに表が空になります
  def test_the_same_table_can_be_read_twice
    table = %(FaRuby.devices { map "start", "R0" }\n)
    with_program("# devices: line.devices.rb\n", table) do |path|
      assert_equal 1, FaRuby::DeviceMap.for_program(path).size
      assert_equal 1, FaRuby::DeviceMap.for_program(path).size
    end
  end

  # === 装置ごとの切り替え ===

  # **装置分を並べておき、`##` で無効にして切り替えられること**
  #
  # 行を消して書き直すと、どの装置の表があったか分からなくなります。
  def test_a_disabled_line_is_ignored
    table = %(FaRuby.devices { map "start", "R0" }\n)
    program = <<~RUBY
      ## devices: line2.devices.rb
      # devices: line.devices.rb
      ## devices: line3.devices.rb
    RUBY
    with_program(program, table) do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_equal "R0", map.mapping["start"]
      assert_includes map.path, "line.devices.rb"
    end
  end

  # 全部無効にすれば割り付けなしになる (実デバイスを直に書く形へ戻せる)
  def test_every_line_disabled_means_no_table
    with_program("## devices: line.devices.rb\n") do |path|
      assert_predicate FaRuby::DeviceMap.for_program(path), :empty?
    end
  end

  # **`##` の付け忘れは止めること。** 先に書いた方を黙って使うと、
  # 別の装置の配線で動いていることに気づけません
  def test_two_live_lines_stop
    program = <<~RUBY
      # devices: line1.devices.rb
      # devices: line2.devices.rb
    RUBY
    with_program(program) do |path|
      error = assert_raises(FaRuby::CodegenError) { FaRuby::DeviceMap.for_program(path) }

      assert_includes error.message, "line1.devices.rb"
      assert_includes error.message, "line2.devices.rb"
      assert_includes error.message, "##"
    end
  end

  # 行の後ろに覚書きを足せる (どの装置かを書いておける)
  def test_a_note_after_the_name_is_allowed
    table = %(FaRuby.devices { map "start", "R0" }\n)
    with_program("# devices: line.devices.rb   1 号ライン (2026-10 更新)\n", table) do |path|
      assert_equal 1, FaRuby::DeviceMap.for_program(path).size
    end
  end

  # === 止める場所 ===

  # ファイル名の書き間違いは転送前に止める
  def test_a_missing_table_stops
    with_program("# devices: typo.devices.rb\n") do |path|
      error = assert_raises(FaRuby::CodegenError) { FaRuby::DeviceMap.for_program(path) }

      assert_includes error.message, "typo.devices.rb"
    end
  end

  # **同じ名前を 2 度書いたら止める。** 後から書いた方が黙って勝つと、
  # 消したつもりの配線が残ります
  def test_a_name_written_twice_stops
    table = <<~RUBY
      FaRuby.devices do
        map "motor", "R500"
        map "motor", "R501"
      end
    RUBY
    with_program("# devices: line.devices.rb\n", table) do |path|
      error = assert_raises(FaRuby::CodegenError) { FaRuby::DeviceMap.for_program(path) }

      assert_includes error.message, "motor"
    end
  end

  # 表の中の Ruby の誤りも、どのファイルかを言って止める
  def test_a_broken_table_stops
    with_program("# devices: line.devices.rb\n", "FaRuby.devices do\n  map \"a\"\n") do |path|
      error = assert_raises(FaRuby::CodegenError) { FaRuby::DeviceMap.for_program(path) }

      assert_includes error.message, "line.devices.rb"
    end
  end

  # プログラムの中に `FaRuby.devices` を書いても動かないこと
  #
  # **プログラムは mrbc に渡すものなので、割り付けを書く場所ではありません。**
  # 黙って無視すると、割り付けたつもりで実デバイスを指します
  def test_the_dsl_only_works_inside_a_table
    error = assert_raises(FaRuby::CodegenError) { FaRuby.devices { map "a", "R0" } }

    assert_includes error.message, "devices:"
  end

  # 割り付け先が実デバイスとして読めるかは**機種が決まってから**見ます
  # (三菱には X / Y があるので、読める名前が違う)
  def test_the_table_itself_does_not_judge_the_target
    table = %(FaRuby.devices { map "motor", "ZZ999" }\n)
    with_program("# devices: line.devices.rb\n", table) do |path|
      map = FaRuby::DeviceMap.for_program(path)

      assert_equal "ZZ999", map.mapping["motor"]
      assert_raises(FaRuby::CodegenError) do
        FaRuby::DeviceSyntax.new(FaRuby::DeviceSet.keyence, mapping: map.mapping)
      end
    end
  end
end
