# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

require_relative "../simulator/kv_vm_simulator"
require_relative "temp_dir"

# any? / all? / none?
#
# **新しいのは「ブロックの戻り値を見る」ことだけです。** ほかの反復
# (`each` / `times` / `upto` / `loop`) はブロックの値を捨てます — `each` は
# レシーバがそのまま呼び出しの値になり、`loop` は `break` でしか終わりません。
# 述語は毎回の値が答えになりうるので、`OP_RETURN` で見ます。
#
# **置き場は増やしていません。** 答えは R[0] (レシーバの位置) に書きます。
# 打ち切る瞬間ともう要素を取り出さない瞬間が同じなので、レシーバを潰して
# よいからです。R[0] は呼んだ側の R[a] と同じ場所なので、それが値になります。
#
# 止める条件と止まったときの値は MemoryLayout::PREDICATE_RULES の 1 か所です。
#   any?  真で止まって true、尽きたら false
#   all?  偽で止まって false、尽きたら true
#   none? 真で止まって false、尽きたら true
class TestPredicates < Minitest::Test
  include FaRuby::VmConstants

  MRBC_PATHS = [
    "C:/mruby-build/mruby/build/host/bin/mrbc.exe",
    File.expand_path("../../mruby/build/host/bin/mrbc.exe", __dir__),
    File.expand_path("../../mruby/build/host/bin/mrbc", __dir__),
  ].freeze

  def setup
    @mrbc = MRBC_PATHS.find { |p| File.executable?(p) }
    skip "mrbc not found" unless @mrbc
  end

  def layout = FaRuby::MemoryLayout.default

  def compile(source)
    Dir.mktmpdir do |dir|
      rb = File.join(dir, "p.rb")
      mrb = File.join(dir, "p.mrb")
      File.write(rb, source, encoding: "utf-8")
      assert system(@mrbc, "-o", mrb, rb, out: File::NULL, err: File::NULL),
             "mrbc に失敗しました"
      return FaRuby::MrbParser.new(File.binread(mrb)).parse.irep
    end
  end

  def run_source(source)
    irep = compile(source)
    sim = FaRuby::KvVmSimulator.new
    sim.load_irep_and_run(irep, max_steps: 200_000)
    sim
  end

  def dm(sim, index) = sim.devices[DEVICE_TYPE_DM].read_s16(index)
  def error_of(sim) = sim.em.read_u16(layout.error_addr)

  def assert_finished(sim)
    assert_equal VM_FINISHED, sim.status, "完了しなかった (error=#{error_of(sim)})"
    assert_equal 0, error_of(sim)
  end

  # 真偽値は $DM に 1 / 0 で落として確かめます
  def assert_predicate_result(source, expected)
    sim = run_source(source)
    assert_finished(sim)
    assert_equal expected, dm(sim, 0)
  end

  # --- any? (配列) ---

  def test_any_は見つかれば真
    assert_predicate_result(<<~RUBY, 1)
      r = [1, 2, 3].any? { |x| x == 2 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_any_は見つからなければ偽
    assert_predicate_result(<<~RUBY, 0)
      r = [1, 2, 3].any? { |x| x == 9 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_空の配列の_any_は偽
    assert_predicate_result(<<~RUBY, 0)
      a = []
      r = a.any? { |x| true }
      $DM0 = r ? 1 : 0
    RUBY
  end

  # **打ち切っていること**を回数で見ます。全部回ると 6 になります
  def test_any_は見つかった時点で打ち切る
    sim = run_source(<<~RUBY)
      n = 0
      [1, 2, 3].any? do |x|
        n = n + x
        x == 2
      end
      $DM0 = n
    RUBY
    assert_finished(sim)
    assert_equal 3, dm(sim, 0)
  end

  # --- all? (配列) ---

  def test_all_は全部真なら真
    assert_predicate_result(<<~RUBY, 1)
      r = [2, 4, 6].all? { |x| x > 1 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_all_は偽が混ざれば偽
    assert_predicate_result(<<~RUBY, 0)
      r = [2, 0, 6].all? { |x| x > 1 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_空の配列の_all_は真
    assert_predicate_result(<<~RUBY, 1)
      a = []
      r = a.all? { |x| false }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_all_は偽を見た時点で打ち切る
    sim = run_source(<<~RUBY)
      n = 0
      [1, 2, 3].all? do |x|
        n = n + x
        x < 2
      end
      $DM0 = n
    RUBY
    assert_finished(sim)
    assert_equal 3, dm(sim, 0)
  end

  # --- none? (配列) ---

  def test_none_は_1_つも無ければ真
    assert_predicate_result(<<~RUBY, 1)
      r = [1, 2, 3].none? { |x| x == 9 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_none_は見つかれば偽
    assert_predicate_result(<<~RUBY, 0)
      r = [1, 2, 3].none? { |x| x == 2 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_空の配列の_none_は真
    assert_predicate_result(<<~RUBY, 1)
      a = []
      r = a.none? { |x| true }
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- nil と false を見分ける ---
  #
  # **0 も真です。** 整数の 0 を返しても真として扱われないと Ruby と違います
  def test_ブロックが_0_を返しても真
    assert_predicate_result(<<~RUBY, 1)
      r = [1].any? { |x| 0 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロックが_nil_を返せば偽
    assert_predicate_result(<<~RUBY, 0)
      r = [1].any? { |x| nil }
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- ハッシュ ---

  def test_ハッシュの_any_は鍵と値を渡す
    assert_predicate_result(<<~RUBY, 1)
      h = { 1 => 10, 2 => 20 }
      r = h.any? { |k, v| k == 2 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ハッシュの_any_は値も見られる
    assert_predicate_result(<<~RUBY, 1)
      h = { 1 => 10, 2 => 20 }
      r = h.any? { |k, v| v == 20 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ハッシュの_all_
    assert_predicate_result(<<~RUBY, 0)
      h = { 1 => 10, 2 => 0 }
      r = h.all? { |k, v| v > 5 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ハッシュの_none_
    assert_predicate_result(<<~RUBY, 1)
      h = { 1 => 10, 2 => 20 }
      r = h.none? { |k, v| v > 99 }
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- ほかの反復を壊していないこと ---

  def test_each_はレシーバを返すまま
    sim = run_source(<<~RUBY)
      n = 0
      a = [1, 2, 3]
      r = a.each { |x| n = n + x }
      $DM0 = n
      $DM1 = r.length
    RUBY
    assert_finished(sim)
    assert_equal 6, dm(sim, 0)
    assert_equal 3, dm(sim, 1)
  end

  def test_times_と_upto_は添字のまま
    sim = run_source(<<~RUBY)
      a = 0
      3.times { |i| a = a + i }
      b = 0
      2.upto(4) { |i| b = b + i }
      $DM0 = a
      $DM1 = b
    RUBY
    assert_finished(sim)
    assert_equal 3, dm(sim, 0)
    assert_equal 9, dm(sim, 1)
  end

  def test_ハッシュの_each_は鍵と値のまま
    sim = run_source(<<~RUBY)
      h = { 1 => 10, 2 => 20 }
      ks = 0
      vs = 0
      h.each { |k, v| ks = ks + k; vs = vs + v }
      $DM0 = ks
      $DM1 = vs
    RUBY
    assert_finished(sim)
    assert_equal 3, dm(sim, 0)
    assert_equal 30, dm(sim, 1)
  end

  # --- 入れ子 ---
  #
  # **打ち切りの旗は 1 つの命令の中でしか生きません。** 内側の any? が
  # 外側の判定を持ち去らないことを見ます
  def test_入れ子の_any_
    assert_predicate_result(<<~RUBY, 1)
      a = [1, 2]
      b = [8, 9]
      r = a.any? do |x|
        b.any? { |y| x + y == 11 }
      end
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- 止める条件の表 ---

  def test_表は_3_つの述語を覆う
    rules = FaRuby::MemoryLayout::PREDICATE_RULES
    assert_equal 3, rules.size
    # 止まったときの値と尽きたときの値は必ず反対
    rules.each_value do |stop_on_true, stopped|
      refute_nil stop_on_true
      refute_nil stopped
    end
    assert_equal [true, true], rules[FaRuby::MemoryLayout::FRAME_KIND_ANY]
    assert_equal [false, false], rules[FaRuby::MemoryLayout::FRAME_KIND_ALL]
    assert_equal [true, false], rules[FaRuby::MemoryLayout::FRAME_KIND_NONE]
  end

  # --- ブロック無し ---
  #
  # **`a.all?` は `a.all? { |x| x }` と同じです。** 中身をそのまま返す
  # ブロック (恒等ブロック) を渡したものとして回すので、判定の規則は
  # ブロック付きと同じ 1 か所です。
  #
  # **ハッシュだけは反復しません。** Ruby はブロック無しのとき
  # `[鍵, 値]` の配列を見るので、中身がどうであれ常に真です。鍵をそのまま
  # 渡すと `{nil => 1}.all?` が偽になってしまいます。

  def test_ブロック無しの_all_は全部真なら真
    assert_predicate_result(<<~RUBY, 1)
      r = [1, 2].all?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_all_は偽が混ざれば偽
    assert_predicate_result(<<~RUBY, 0)
      r = [1, nil, 2].all?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_all_は_false_も偽として見る
    assert_predicate_result(<<~RUBY, 0)
      a = [true, false]
      r = a.all?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_any_は真が1つでもあれば真
    assert_predicate_result(<<~RUBY, 1)
      a = [nil, false, 1]
      r = a.any?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_any_は全部偽なら偽
    assert_predicate_result(<<~RUBY, 0)
      a = [nil, false]
      r = a.any?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_none_は全部偽なら真
    assert_predicate_result(<<~RUBY, 1)
      a = [nil, false]
      r = a.none?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ブロック無しの_none_は真があれば偽
    assert_predicate_result(<<~RUBY, 0)
      a = [nil, 1]
      r = a.none?
      $DM0 = r ? 1 : 0
    RUBY
  end

  # 0 は Ruby では真。整数の中身で判定していないこと
  def test_ブロック無しの_any_は_0_を真として見る
    assert_predicate_result(<<~RUBY, 1)
      a = [0]
      r = a.any?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_空の配列はブロック無しでも同じ答え
    assert_predicate_result(<<~RUBY, 1)
      a = []
      r = a.all? && a.none? && !a.any?
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- ブロック無し (ハッシュ) ---

  def test_ハッシュのブロック無しの_all_は常に真
    assert_predicate_result(<<~RUBY, 1)
      h = { a: nil }
      r = h.all?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ハッシュのブロック無しの_any_は空でなければ真
    assert_predicate_result(<<~RUBY, 1)
      h = { a: nil }
      r = h.any?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_ハッシュのブロック無しの_none_は空でなければ偽
    assert_predicate_result(<<~RUBY, 0)
      h = { a: 1 }
      r = h.none?
      $DM0 = r ? 1 : 0
    RUBY
  end

  def test_空のハッシュはブロック無しで_any_が偽
    assert_predicate_result(<<~RUBY, 1)
      h = {}
      r = !h.any? && h.all? && h.none?
      $DM0 = r ? 1 : 0
    RUBY
  end

  # --- 恒等ブロックの置き場 ---

  # **使っているときだけ足します。** irep を 1 枠使うので (max_ireps は 16)
  #
  # ブロック付きも irep が 1 つ増えますが、それは**利用者のブロック**です。
  # 中身で見分けます (恒等ブロックは `OP_RETURN R[1]` の 2 バイト)。
  def test_ブロック無しのときだけ恒等ブロックが増える
    plain      = ireps_of("$DM0 = [1].length\n")
    blockless  = ireps_of("$DM0 = [1].all? ? 1 : 0\n")
    with_block = ireps_of("$DM0 = [1].all? { |x| x } ? 1 : 0\n")

    assert_equal 1, plain.size, "述語を呼んでいないので足さない"
    assert_equal 2, blockless.size, "恒等ブロックが 1 つ増える"
    assert_equal [56, 1], blockless.last.instructions.bytes

    assert_equal 2, with_block.size, "利用者のブロックだけ。恒等は足さない"
    refute_equal [56, 1], with_block.last.instructions.bytes,
                 "ブロック付きに恒等ブロックを足してはいけない"
  end

  # **最後に置くのが約束です。** VM は num_ireps - 1 で引きます
  def test_恒等ブロックは最後の_irep
    codegen = codegen_for("$DM0 = [1].all? ? 1 : 0\n")
    last = codegen.send(:irep_entries).last[:irep]

    assert_equal 2, last.ilen, "OP_RETURN R[1] の 2 バイト"
    assert_equal [56, 1], last.instructions.bytes, "OP_RETURN R[1]"
  end

  def codegen_for(source)
    FaRuby::PlcCodegen.new(compile(source), layout: layout)
  end

  def ireps_of(source)
    codegen_for(source).send(:irep_entries).map { |entry| entry[:irep] }
  end
end
