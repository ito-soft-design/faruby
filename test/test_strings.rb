# frozen_string_literal: true

require "minitest/autorun"

require_relative "../tools/config"
require_relative "../tools/vm_constants"
require_relative "../tools/memory_layout"
require_relative "../tools/opcode_table"
require_relative "../tools/kvs_generator"
require_relative "../simulator/kv_vm_simulator"

# 文字列
#
# 実体は配列プールのスロットに置き、見出しの後ろに 1 ワード 2 バイトで
# 詰めます。**先の文字が上位バイト**で、KV-5000 の文字列デバイスと同じ並びです。
# バイト列は変換しないため、デバイスへの書き込みはワード単位の写しで済みます。
#
# mrbc を通すため、mrbc が見つからない環境では実行時テストを飛ばします。
class TestStrings < Minitest::Test
  include FaRuby::VmConstants

  Layout = FaRuby::MemoryLayout

  def layout = Layout.default

  def mrbc_path
    @mrbc_path ||= begin
      FaRuby::Config.new(nil).mrbc_path
    rescue StandardError
      nil
    end
  end

  def run_source(source)
    skip "mrbc が見つかりません" unless mrbc_path && File.exist?(mrbc_path)

    dir = File.expand_path("../tmp", __dir__)
    Dir.mkdir(dir) unless Dir.exist?(dir)
    src = File.join(dir, "strings_test.rb")
    mrb = File.join(dir, "strings_test.mrb")
    File.binwrite(src, source)
    assert system(mrbc_path, "-o", mrb, src, out: File::NULL, err: File::NULL), "mrbc に失敗"

    parser = FaRuby::MrbParser.new(File.binread(mrb))
    parser.parse
    sim = FaRuby::KvVmSimulator.new(layout: layout)
    sim.load_irep_and_run(parser.irep, max_steps: 100_000,
                          encoding: FaRuby::PlcCodegen.detect_encoding(source))
    sim
  ensure
    [src, mrb].each { |f| File.delete(f) if f && File.exist?(f) }
  end

  # シンボルだけを持つ irep (デバイステーブルの検査用)
  def irep_with(symbols)
    irep = FaRuby::Irep.new
    irep.nregs = 8
    irep.nlocals = 2
    irep.instructions = "i" # OP_STOP
    irep.ilen = irep.instructions.bytesize
    symbols.each { |s| irep.add_symbol(s) }
    irep
  end

  def status(sim) = sim.em.read_u16(layout.status_addr)
  def error(sim)  = sim.em.read_u16(layout.error_addr)

  # DM を 16 進のワード列で読む
  def words(sim, base, count)
    dm = sim.devices[DEVICE_TYPE_DM]
    (0...count).map { |i| dm.read_u16(base + i) }
  end

  # $DM0 を 16 ビット符号付きで読んで突き合わせる
  def assert_result(expected, source)
    sim = run_source(source)
    assert_finished sim
    value = sim.devices[DEVICE_TYPE_DM].read_u16(0)
    value -= 65_536 if value > 32_767
    assert_equal expected, value
  end

  def assert_finished(sim)
    assert_equal VM_FINISHED, status(sim), "実行が完了しなかった (error=#{error(sim)})"
  end

  # === OP_STRING ===

  def test_a_literal_lands_in_a_pool_slot
    sim = run_source(%(s = "hello"\n))

    assert_finished sim
    assert_equal 1, sim.em.read_u16(layout.array_sp_addr), "スロットを 1 つ使う"
    assert_equal "hello", string_bytes(sim, 0)
  end

  # Ruby の文字列は変更できるので、同じリテラルを 2 回書けば別のもの
  def test_the_same_literal_twice_takes_two_slots
    sim = run_source(%(s = "hi"\nt = "hi"\n))

    assert_equal 2, sim.em.read_u16(layout.array_sp_addr)
    assert_equal "hi", string_bytes(sim, 0)
    assert_equal "hi", string_bytes(sim, 1)
  end

  # 1 ワードに 2 バイト、先の文字が上位。KV-5000 と同じ並び
  def test_bytes_pack_two_to_a_word_with_the_first_byte_high
    sim = run_source(%(s = "ABCDE "\n))
    slot = layout.string_word_addr(0, 0)

    assert_equal 0x4142, sim.em.read_u16(slot)
    assert_equal 0x4344, sim.em.read_u16(slot + 1)
    assert_equal 0x4520, sim.em.read_u16(slot + 2)
  end

  # バイト列は変換しない。ソースのバイトがそのまま入る
  def test_bytes_are_not_converted
    sim = run_source(%(s = "あ"\n))

    assert_equal "\xE3\x81\x82".b, string_bytes(sim, 0)
  end

  def test_an_empty_literal
    sim = run_source(%(s = ""\n))

    assert_finished sim
    assert_equal "", string_bytes(sim, 0)
  end

  # 返さないスロットを使うため、ループの中のリテラルは使い切る
  def test_literals_in_a_loop_exhaust_the_pool
    sim = run_source(<<~RUBY)
      #{layout.max_arrays + 1}.times do |i|
        s = "x"
      end
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal 10, error(sim)
  end

  # === FARUBY_STR_FILL ===

  def test_the_setting_constant_reaches_vm_state
    sim = run_source("FARUBY_STR_FILL = 0x20\n")

    assert_finished sim
    assert_equal 0x20, sim.em.read_u16(layout.str_fill_addr)
  end

  def test_the_fill_defaults_to_zero
    sim = run_source(%(s = "a"\n))

    assert_equal 0, sim.em.read_u16(layout.str_fill_addr)
  end

  # 接頭辞で始まらない定数は利用者のもの。何もしない
  def test_an_ordinary_constant_is_ignored
    sim = run_source("MY_LIMIT = 5\n")

    assert_finished sim
    assert_equal 0, sim.em.read_u16(layout.str_fill_addr)
  end

  # === 終端付きの書き込み ===

  # 書き方は増えない。値が文字列かどうかは実行時のタグで分かる
  def test_a_terminated_write_adds_a_zero
    sim = run_source(%($DM800 = "abc"\n))

    assert_finished sim
    assert_equal [0x6162, 0x6300], words(sim, 800, 2)
  end

  # 偶数バイトなら終端に 1 ワード余分に要る
  def test_an_even_length_string_takes_another_word_for_the_terminator
    sim = run_source(%($DM800 = "abcd"\n))

    assert_equal [0x6162, 0x6364, 0x0000], words(sim, 800, 3)
  end

  def test_an_empty_string_writes_only_the_terminator
    sim = run_source(%($DM800 = ""\n))

    assert_equal [0x0000], words(sim, 800, 1)
  end

  # === 固定長の書き込み ===

  def test_a_short_string_is_padded_with_the_fill
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "abc"
    RUBY

    assert_finished sim
    assert_equal [0x6162, 0x6320, 0x2020], words(sim, 800, 3)
  end

  # 埋めないと前に書いた長い文字列の尻尾が残る
  def test_the_fill_wipes_what_a_longer_write_left
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "abcdef"
      $DM800T6 = "xy"
    RUBY

    assert_equal [0x7879, 0x2020, 0x2020], words(sim, 800, 3)
  end

  # ちょうどなら終端を書かない。書くと次の桁にはみ出す
  def test_an_exact_fit_writes_no_terminator
    sim = run_source(%($DM800T6 = "ABCDEF"\n))

    assert_equal [0x4142, 0x4344, 0x4546, 0x0000], words(sim, 800, 4)
  end

  # 表示器の桁は決まっている。止めるより書く
  def test_a_long_string_is_truncated
    sim = run_source(%($DM800T4 = "abcdefgh"\n))

    assert_finished sim
    assert_equal [0x6162, 0x6364], words(sim, 800, 2)
  end

  # 桁数が奇数なら最後のワードの下位バイトは桁の外。ワード単位でしか書けない
  def test_an_odd_width_leaves_zero_outside_the_field
    sim = run_source(<<~RUBY)
      FARUBY_STR_FILL = 0x20
      $DM800T5 = "ab"
    RUBY

    assert_equal [0x6162, 0x2020, 0x2000], words(sim, 800, 3)
  end

  def test_the_fill_defaults_to_zero_when_the_program_does_not_set_it
    sim = run_source(%($DM800T6 = "abc"\n))

    assert_equal [0x6162, 0x6300, 0x0000], words(sim, 800, 3)
  end

  # === 中身で比べる ===
  #
  # スロット番号だけを比べると、同じ内容が別のスロットにあるときに等しくならない

  def test_the_same_content_in_two_slots_is_equal
    assert_result 1, <<~RUBY
      s = "hello"
      t = "hello"
      $DM0 = 0
      if s == t
        $DM0 = 1
      end
    RUBY
  end

  def test_different_content_of_the_same_length_is_not_equal
    assert_result 0, <<~RUBY
      $DM0 = 0
      if "hello" == "hellp"
        $DM0 = 1
      end
    RUBY
  end

  def test_a_different_length_is_not_equal
    assert_result 0, <<~RUBY
      $DM0 = 0
      if "hello" == "hell"
        $DM0 = 1
      end
    RUBY
  end

  def test_not_equal_is_the_negation
    assert_result 1, <<~RUBY
      $DM0 = 0
      if "a" != "b"
        $DM0 = 1
      end
    RUBY
  end

  # 型が違えば中身を見るまでもない
  def test_a_string_is_not_equal_to_a_number
    assert_result 0, <<~RUBY
      $DM0 = 0
      if "5" == 5
        $DM0 = 1
      end
    RUBY
  end

  # 日本語も同じ。バイト列をそのまま比べる
  def test_multibyte_content
    assert_result 1, <<~RUBY
      $DM0 = 0
      if "あい" == "あい"
        $DM0 = 1
      end
    RUBY
  end

  # === 文字列の鍵 ===

  def test_a_string_key_is_found_by_content
    assert_result 8, %($DM0 = { "x" => 7, "y" => 8 }["y"]\n)
  end

  def test_key_p_with_a_string
    assert_result 1, <<~RUBY
      h = { "x" => 7 }
      $DM0 = 0
      if h.key?("x")
        $DM0 = 1
      end
    RUBY
  end

  def test_writing_an_existing_string_key_replaces_the_value
    assert_result 11, <<~RUBY
      h = { "x" => 7 }
      h["x"] = 11
      $DM0 = h["x"]
    RUBY
  end

  def test_a_new_string_key_is_appended
    assert_result 9, <<~RUBY
      h = { "x" => 7 }
      h["z"] = 9
      $DM0 = h["z"]
    RUBY
  end

  # === 連結 ===

  def test_plus_makes_a_new_string
    sim = run_source(%($DM800 = "ab" + "cd"\n))

    assert_finished sim
    assert_equal [0x6162, 0x6364], words(sim, 800, 2)
  end

  # 継ぎ足す先の長さが奇数だとワードの途中から始まる
  def test_plus_across_a_word_boundary
    sim = run_source(%($DM800 = "abc" + "de"\n))

    assert_equal [0x6162, 0x6364, 0x6500], words(sim, 800, 3)
  end

  # + は左側を変えない。新しいスロットを取る
  def test_plus_leaves_the_left_side_alone
    sim = run_source(<<~RUBY)
      a = "ab"
      b = a + "cd"
      $DM800 = a
    RUBY

    assert_equal [0x6162, 0x0000], words(sim, 800, 2)
  end

  # 式展開は OP_STRING と OP_STRCAT になる
  def test_interpolation
    sim = run_source(<<~'RUBY')
      s = "x"
      $DM800 = "p#{s}q"
    RUBY

    assert_equal [0x7078, 0x7100], words(sim, 800, 2)
  end

  # 日本語をまたいで継ぎ足す。3 バイト目が次のワードの下位に入る
  def test_concatenating_multibyte_strings
    sim = run_source(%($DM800 = "あ" + "い"\n))

    assert_equal [0xE381, 0x82E3, 0x8184], words(sim, 800, 3)
  end

  def test_concatenating_onto_an_empty_string
    sim = run_source(%($DM800 = "" + "z"\n))

    assert_equal [0x7A00], words(sim, 800, 1)
  end

  # 1 スロットに収まらない連結は止まる
  def test_a_concatenation_past_the_capacity_stops_the_vm
    half = "a" * (layout.max_string_bytes / 2 + 1)
    sim = run_source(%($DM800 = "#{half}" + "#{half}"\n))

    assert_equal VM_ERROR, status(sim)
    assert_equal 10, error(sim)
  end

  # === 長さ ===
  #
  # length は**文字数**を返す。バイト数ではない

  def test_length_counts_ascii_characters
    assert_result 5, %($DM0 = "hello".length\n)
  end

  def test_size_is_the_same_as_length
    assert_result 5, %($DM0 = "hello".size\n)
  end

  # "あ" は UTF-8 で 3 バイトだが 1 文字
  def test_length_counts_utf8_characters
    assert_result 2, %($DM0 = "あい".length\n)
  end

  def test_length_of_a_mixed_string
    assert_result 4, %($DM0 = "aあbい".length\n)
  end

  def test_length_of_an_empty_string
    assert_result 0, %($DM0 = "".length\n)
  end

  # Shift_JIS は先導バイト (0x81-0x9F, 0xE0-0xEF) の次を後続バイトとして飛ばす。
  # **自己同期しない**ので、必ず先頭から数える
  def test_length_counts_shift_jis_characters
    source = %(# encoding: shift_jis\n$DM0 = "\x82\xa0\x82\xa2".length\n)

    assert_result 2, source.dup.force_encoding("shift_jis")
  end

  # 配列とハッシュの length は今までどおり要素数
  def test_length_still_counts_array_elements
    assert_result 3, %($DM0 = [1, 2, 3].length\n)
  end

  # === empty? ===

  def test_an_empty_string_is_empty
    assert_result 1, <<~RUBY
      $DM0 = 0
      if "".empty?
        $DM0 = 1
      end
    RUBY
  end

  def test_a_string_with_content_is_not_empty
    assert_result 0, <<~RUBY
      $DM0 = 0
      if "a".empty?
        $DM0 = 1
      end
    RUBY
  end

  def test_an_empty_array_is_empty
    assert_result 1, <<~RUBY
      $DM0 = 0
      if [].empty?
        $DM0 = 1
      end
    RUBY
  end

  def test_empty_takes_a_string_an_array_and_a_hash
    assert_equal [TT_STRING, TT_HASH],
                 method_receiver_tags(BUILTIN_METHODS.fetch("empty?").first)
  end

  # === << ===

  # 文字列の << は中身を継ぎ足す。Ruby と同じくレシーバ自身を返す
  def test_shovel_appends_to_a_string
    sim = run_source(<<~RUBY)
      s = "ab"
      s << "cd"
      $DM800 = s
    RUBY

    assert_equal [0x6162, 0x6364], words(sim, 800, 2)
  end

  def test_shovel_across_a_word_boundary
    sim = run_source(<<~RUBY)
      s = "abc"
      s << "de"
      $DM800 = s
    RUBY

    assert_equal [0x6162, 0x6364, 0x6500], words(sim, 800, 3)
  end

  # 継ぎ足す先はそのまま伸びる。+ と違って新しいスロットは取らない
  def test_shovel_keeps_the_same_slot
    assert_result 4, <<~RUBY
      s = "ab"
      t = s
      s << "cd"
      $DM0 = t.length
    RUBY
  end

  def test_shovel_still_pushes_onto_an_array
    assert_result 3, <<~RUBY
      a = [1, 2]
      a << 3
      $DM0 = a.length
    RUBY
  end

  # push は配列だけ。Ruby の String に push は無い
  def test_push_is_array_only
    assert_equal [TT_ARRAY, TT_ARRAY],
                 method_receiver_tags(BUILTIN_METHODS.fetch("push").first)
  end

  def test_shovel_with_a_number_stops_the_vm
    sim = run_source(<<~RUBY)
      s = "ab"
      s << 1
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::METHOD_TYPE_ERROR, error(sim)
  end

  # 1 スロットに収まらない << は止まる
  def test_a_shovel_past_the_capacity_stops_the_vm
    half = "a" * (layout.max_string_bytes / 2 + 1)
    sim = run_source(<<~RUBY)
      s = "#{half}"
      s << "#{half}"
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::HEAP_ERROR, error(sim)
  end

  # === s[i] ===
  #
  # Ruby と同じく 1 文字の文字列を返す。プールを 1 スロット使う

  def test_index_returns_one_character
    sim = run_source(%($DM800 = "abc"[1]\n))

    assert_equal [0x6200], words(sim, 800, 1)
  end

  def test_index_returns_a_multibyte_character
    sim = run_source(%($DM800 = "あい"[1]\n))

    assert_equal [0xE381, 0x8400], words(sim, 800, 2)
  end

  # 負の添字は後ろから数える (Ruby の s[-1] は最後の文字)
  def test_a_negative_index_counts_from_the_end
    sim = run_source(%($DM800 = "abc"[-1]\n))

    assert_equal [0x6300], words(sim, 800, 1)
  end

  def test_a_negative_index_past_the_front_is_nil
    assert_result 0, %($DM0 = "abc"[-4]\n)
  end

  # 範囲外は nil。エラーにはしない (Ruby と同じ)
  def test_an_index_past_the_end_is_nil
    assert_result 2, <<~RUBY
      $DM0 = 1
      if "abc"[3] == nil
        $DM0 = 2
      end
    RUBY
  end

  def test_an_index_into_an_empty_string_is_nil
    assert_result 0, %($DM0 = ""[0]\n)
  end

  # 1 文字ごとにスロットを取るので、ループの中では使い切る
  def test_index_takes_a_pool_slot
    sim = run_source(<<~RUBY)
      s = "abcdefghijklmnop"
      i = 0
      while i < 16
        t = s[i]
        i = i + 1
      end
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::HEAP_ERROR, error(sim)
  end

  # === 生成コードの見張り ===

  # Z6 は走査の FOR の上限。中で書き換えるとループが壊れる
  def test_the_character_scan_does_not_clobber_the_loop_limit
    source = FaRuby::KvsGenerator.new.source
    scan = source[/文字の切れ目を先頭から数える。バイト列は 1 回だけなめる\n(.*?)\n\s*NEXT\n/m, 1]
    refute_nil scan, "走査が見つからない"

    inside = scan[/FOR .*\n(.*)/m]
    refute_match(/^\s+Z6 = /, inside, "FOR の上限を書き換えている")
  end

  # === デバイスから読む ===
  #
  # 桁数がそのままバイト数。**何も落とさない**

  def test_a_fixed_width_read_gives_the_bytes_back
    assert_result 1, <<~RUBY
      $DM800T6 = "ABCDEF"
      $DM0 = 0
      if $DM800T6 == "ABCDEF"
        $DM0 = 1
      end
    RUBY
  end

  def test_a_read_counts_the_field_as_bytes
    assert_result 6, <<~RUBY
      $DM800T6 = "ABCDEF"
      $DM0 = $DM800T6.length
    RUBY
  end

  # 桁が埋め物で埋まっていれば、その埋め物も中身に入る
  def test_a_read_keeps_the_padding
    assert_result 6, <<~RUBY
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "AB"
      $DM0 = $DM800T6.length
    RUBY
  end

  def test_a_short_string_read_back_is_not_equal_to_itself
    assert_result 0, <<~RUBY
      FARUBY_STR_FILL = 0x20
      $DM800T6 = "AB"
      $DM0 = 0
      if $DM800T6 == "AB"
        $DM0 = 1
      end
    RUBY
  end

  # 奇数の桁は最後のワードの下位バイトが桁の外。混ぜると == が外れる
  def test_an_odd_width_read_drops_the_byte_outside_the_field
    sim = run_source(<<~RUBY)
      $DM800T3 = "xyz"
      $DM810 = 0
      $DM811 = 0
      $DM0 = 0
      if $DM800T3 == "xyz"
        $DM0 = 1
      end
    RUBY

    assert_finished sim
    assert_equal 1, sim.devices[DEVICE_TYPE_DM].read_u16(0)
  end

  # UTF-8 は 1 文字 3 バイト。桁はバイト数で数える
  def test_a_read_of_multibyte_content
    assert_result 2, <<~RUBY
      $DM800T6 = "あい"
      $DM0 = $DM800T6.length
    RUBY
  end

  # 桁の無い T は書くときは終端付きだが、読むときは長さが決まらない
  def test_a_read_without_a_width_stops_the_vm
    sim = run_source(%($DM0 = $DM800T\n))

    assert_equal VM_ERROR, status(sim)
    assert_equal 0x15, error(sim)
  end

  # 1 スロットに収まらない桁数
  def test_a_read_past_the_capacity_stops_the_vm
    sim = run_source("$DM0 = $DM800T#{layout.max_string_bytes + 2}\n")

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::HEAP_ERROR, error(sim)
  end

  # 読むたびにスロットを取るので、ループの中では使い切る
  def test_a_read_takes_a_pool_slot
    sim = run_source(<<~RUBY)
      i = 0
      while i < 20
        s = $DM800T4
        i = i + 1
      end
    RUBY

    assert_equal VM_ERROR, status(sim)
    assert_equal FaRuby::OpcodeTable::HEAP_ERROR, error(sim)
  end

  # 添字を付けた形。桁は名前側に付ける
  def test_an_indexed_read
    assert_result 1, <<~RUBY
      $DM800T6 = "ABCDEF"
      i = 0
      $DM0 = 0
      if $DMT6[800 + i] == "ABCDEF"
        $DM0 = 1
      end
    RUBY
  end

  def test_an_indexed_write
    sim = run_source(<<~RUBY)
      i = 0
      $DMT4[800 + i] = "abcd"
    RUBY

    assert_equal [0x6162, 0x6364], words(sim, 800, 2)
  end

  # 文字列の桁 (T) に文字列以外を書こうとした
  def test_an_indexed_write_of_a_number_stops_the_vm
    sim = run_source(<<~RUBY)
      i = 0
      $DMT4[800 + i] = 5
    RUBY

    assert_equal VM_ERROR, status(sim)
  end

  # ビットデバイスには文字列を置けない。族の形も転送前に止める
  def test_a_string_field_on_a_bit_device_family_stops_the_build
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.parse_device_family("$MRT6") }
  end

  # === 桁付きはシンボル種別で分ける ===
  #
  # 桁が付いているかは転送前に分かる。種別に持たせておくと OP_GETGV が
  # **種別を 1 回見るだけ**で済み、普通の読み取りが 1 比較で通る。
  # 命令の本体に置いた比較はその命令が走るたびに効くため

  def test_a_string_field_gets_its_own_symbol_kind
    mappings = FaRuby::PlcCodegen.new(irep_with(%w[$DM100T6 $DM100 $DMT6])).device_mappings

    assert_equal SYMBOL_KIND_STR_DEVICE, mappings[0][:kind], "$DM100T6"
    assert_equal SYMBOL_KIND_VALUE, mappings[1][:kind], "$DM100"
    assert_equal SYMBOL_KIND_FAMILY, mappings[2][:kind], "$DMT6 は族のまま"
  end

  # 普通の読み取りが先頭に来ていること。後ろへ回すと 1 比較ぶん遅くなる
  def test_the_common_read_comes_first
    source = FaRuby::KvsGenerator.new.source
    body = source[/' OP_GETGV .*?\n(.*?)\n\s+ELSE IF EM6:Z9 = /m, 1]
    refute_nil body, "OP_GETGV が見つからない"

    first = body[/^\s+IF Z1 = (\d+) THEN/, 1]

    assert_equal SYMBOL_KIND_VALUE.to_s, first, "普通のデバイスを先に見ること"
  end

  # === 弾くもの ===

  # 文字列の桁 (T) に文字列以外を書こうとした
  def test_a_number_to_a_string_field_stops_the_vm
    sim = run_source("$DM800T6 = 5\n")

    assert_equal VM_ERROR, status(sim)
  end

  # ビットデバイスは転送前に止まる。表示器から読めないため
  def test_a_string_field_on_a_bit_device_stops_the_build
    assert_raises(FaRuby::CodegenError) { FaRuby::PlcCodegen.parse_device_name("MR100T6") }
  end

  # === 生成コード ===

  # Z6 はデバイスのベースアドレス。写している途中で壊すと書き先がずれる
  def test_the_string_write_does_not_clobber_the_base_address
    source = FaRuby::KvsGenerator.new.source
    branch = source[/ELSE IF EM0:Z2 = #{TT_STRING} THEN\n(.*?)\n                ELSE\n/m, 1]
    refute_nil branch, "文字列の書き込みが見つからない"

    refute_match(/^\s+Z6 = /, branch, "ベースアドレスを書き換えている")
  end

  # FOR の中で BREAK すると FOR を抜けるだけで命令ループから出られない。
  # エラーを書いてもそのまま走り続け、最後に STOP が status を上書きする。
  # デバイス種別の検査は写しの FOR に入る前に済ませる
  def test_the_string_write_does_not_break_inside_the_loop
    source = FaRuby::KvsGenerator.new.source
    branch = source[/ELSE IF EM0:Z2 = #{TT_STRING} THEN\n(.*?)\n                ELSE\n/m, 1]
    refute_nil branch, "文字列の書き込みが見つからない"

    inside = branch[/FOR Z\d+ = 0 TO.*?\n\s*NEXT/m]
    refute_nil inside, "写しの FOR が見つからない"
    refute_includes inside, "BREAK", "FOR の中で BREAK すると FOR を抜けるだけになる"
  end

  def test_string_opcodes_are_implemented
    codes = FaRuby::OpcodeTable.codes

    assert_includes codes, 0x51, "OP_STRING が未実装"
    assert_includes codes, 0x1E, "OP_SETCONST が未実装"
    refute_includes codes, 0x1D, "OP_GETCONST は実装しない (設定を読む必要が無い)"
  end

  private

  # スロットのバイト列
  def string_bytes(sim, slot)
    length = sim.em.read_u16(layout.array_slot_addr(slot) + Layout::ARRAY_LENGTH)
    bytes = +""
    ((length + 1) / 2).times do |i|
      word = sim.em.read_u16(layout.string_word_addr(slot, i))
      bytes << (word >> 8).chr << (word & 0xFF).chr
    end
    bytes.byteslice(0, length)
  end
end
