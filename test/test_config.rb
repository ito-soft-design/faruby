# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../tools/config"

# 設定の読み込み
#
# **機種ごとの設定は共通設定を上書きします。**書いた項目だけが差し替わり、
# 書かなかった項目は共通のまま残ります。どちらが勝つかを間違えると、
# 別の PLC の設定で転送してしまうので、ここで押さえておきます。
class TestConfig < Minitest::Test
  # 利用者設定を一時ファイルに書いて読ませる。
  # パスを渡さないとリポジトリの faruby.yml を拾うため、必ず渡す。
  def with_config(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "faruby.yml")
      File.write(path, yaml, encoding: "utf-8")
      yield path
    end
  end

  # === 機種の選択 ===

  def test_the_default_model_comes_from_the_defaults_file
    with_config("plc:\n  host: 10.0.0.1\n") do |path|
      assert_equal "KV-5000", FaRuby::Config.new(path).model
    end
  end

  def test_plc_model_selects_the_model
    with_config("plc:\n  model: KV-X500\n") do |path|
      assert_equal "KV-X500", FaRuby::Config.new(path).model
    end
  end

  # 呼ぶ側 (コンソールの --model、rake の全機種生成) が押し切れること
  def test_the_argument_wins_over_plc_model
    with_config("plc:\n  model: KV-5000\n") do |path|
      assert_equal "KV-X500", FaRuby::Config.new(path, model: "KV-X500").model
    end
  end

  # 綴じ間違いは黙って無視されると気づけない
  def test_an_unknown_model_is_refused
    with_config("plc:\n  model: KV-5500\n") do |path|
      error = assert_raises(FaRuby::ConfigError) { FaRuby::Config.new(path) }
      assert_includes error.message, "KV-5500"
    end
  end

  def test_an_unknown_model_section_is_refused
    with_config("models:\n  KV-9999:\n    plc:\n      host: 10.0.0.9\n") do |path|
      error = assert_raises(FaRuby::ConfigError) { FaRuby::Config.new(path) }
      assert_includes error.message, "KV-9999"
    end
  end

  # === 機種ごとの上書き ===

  def test_the_model_section_overrides_the_common_setting
    yaml = <<~YAML
      plc:
        host: 10.0.0.1
      models:
        KV-X500:
          plc:
            host: 10.0.0.2
    YAML
    with_config(yaml) do |path|
      assert_equal "10.0.0.1", FaRuby::Config.new(path, model: "KV-5000").plc_host
      assert_equal "10.0.0.2", FaRuby::Config.new(path, model: "KV-X500").plc_host
    end
  end

  # **書いた項目だけが差し替わる。**残りは共通のまま
  def test_the_model_section_leaves_the_rest_of_the_common_setting
    yaml = <<~YAML
      plc:
        host: 10.0.0.1
        port: 8502
      models:
        KV-X500:
          plc:
            host: 10.0.0.2
    YAML
    with_config(yaml) do |path|
      config = FaRuby::Config.new(path, model: "KV-X500")

      assert_equal ["10.0.0.2", 8502], [config.plc_host, config.plc_port]
    end
  end

  def test_memory_and_vm_settings_can_differ_by_model
    yaml = <<~YAML
      vm:
        steps_per_cycle: 50
      memory:
        base: 20000
      models:
        KV-X500:
          vm:
            steps_per_cycle: 30
          memory:
            base: 24000
    YAML
    with_config(yaml) do |path|
      kv5000 = FaRuby::Config.new(path, model: "KV-5000")
      x500   = FaRuby::Config.new(path, model: "KV-X500")

      assert_equal [50, 20_000], [kv5000.steps_per_cycle, kv5000.layout.base]
      assert_equal [30, 24_000], [x500.steps_per_cycle, x500.layout.base]
    end
  end

  # 機種を書かなかった項目は既定の配置のまま。上書きは base だけ
  def test_a_model_section_does_not_disturb_the_rest_of_the_layout
    yaml = "models:\n  KV-X500:\n    memory:\n      base: 24000\n"
    with_config(yaml) do |path|
      config = FaRuby::Config.new(path, model: "KV-X500")

      assert_equal 24_000, config.layout.base
      assert_equal FaRuby::Config.defaults.layout.instances, config.layout.instances
    end
  end

  # === 機種の切り替え ===

  # 生成 (rake vm_core) が全機種を回すときに使う
  def test_for_model_reads_the_same_file_for_another_model
    yaml = "models:\n  KV-X500:\n    memory:\n      base: 24000\n"
    with_config(yaml) do |path|
      config = FaRuby::Config.new(path, model: "KV-5000")
      other = config.for_model("KV-X500")

      assert_equal "KV-X500", other.model
      assert_equal 24_000, other.layout.base
      assert_equal 20_000, config.layout.base
    end
  end

  def test_for_model_returns_itself_for_the_same_model
    with_config("plc:\n  model: KV-5000\n") do |path|
      config = FaRuby::Config.new(path)

      assert_same config, config.for_model("KV-5000")
    end
  end

  # 既定値だけを読む経路でも機種を選べること (生成物の再現性検証で使う)
  def test_the_defaults_only_config_can_switch_models
    assert_equal "KV-X500", FaRuby::Config.defaults.for_model("KV-X500").model
  end

  # === 既定設定 ===

  # **機種の欄を見れば、その機種の設定が全部揃っている**形にしてあります。
  # 共通の位置に既定値を置いていないので、機種を増やして欄を作り忘れると
  # 値が欠けたまま動きます。
  def test_every_model_has_a_complete_default
    FaRuby::Dialect.models.each do |model|
      config = FaRuby::Config.defaults.for_model(model)
      missing = { "plc.protocol" => config.plc_protocol,
                  "plc.port" => config.plc_port,
                  "vm.steps_per_cycle" => config.steps_per_cycle }.select { |_, v| v.nil? }

      assert_empty missing.keys, "#{model} の既定値が欠けています"
      assert_operator config.layout.base, :>, 0, "#{model} のメモリ配置"
    end
  end
end
