# frozen_string_literal: true

require_relative "vm_constants"
require_relative "device_set"

module FaRuby
  # 生成できない書き方を見つけたとき
  #
  # **綴りの誤りは転送する前に止めます。** PLC まで持っていってから
  # 気づくと、何が悪いのか分かりません。
  class CodegenError < StandardError; end

  # Ruby プログラムに書いたデバイスの読み方
  #
  # **`$DM100` や `$D100` をどう読むかはメーカーごとに違います。** 名前が違う
  # だけでなく、アドレスの数え方 (10 進・16 進・チャンネル/ビット) も違います。
  #
  # 表は tools/device_set.rb が持ち、ここはそれを正規表現と番号に直す係です。
  # **種別を増やしても正規表現を書き直す必要はありません。**
  class DeviceSyntax
    include VmConstants

    # 幅サフィックス。`$DM100L` の `L`
    SUFFIX = "(?:_?(L|D|U|S|F|T\\d*))?"

    # access_type に詰められる桁数の上限 (16ビットに収まる範囲)
    MAX_STRING_FIELD = 4095

    attr_reader :device_set, :mapping

    # mapping:        割り付け表 (抽象的な名前 => 実デバイス)
    # warn_unmapped:  表を通らずに実デバイスとして読んだ名前を覚えておくか
    def initialize(device_set, mapping: {}, warn_unmapped: false)
      @device_set = device_set
      @mapping = mapping.to_h { |name, target| [name.to_s, target.to_s] }
      @warn_unmapped = warn_unmapped
      @unmapped = []
      validate_mapping!
    end

    def self.keyence = @keyence ||= new(DeviceSet.keyence)
    def self.melsec  = @melsec  ||= new(DeviceSet.melsec)

    # 機種の綴り方から引く
    def self.for_dialect(dialect, mapping: {}, warn_unmapped: false)
      new(dialect.device_set, mapping: mapping, warn_unmapped: warn_unmapped)
    end

    # 表を通らずに実デバイスとして読んだ名前 (出現順、重複なし)
    #
    # **全部を抽象化したい設備で `$R0` の直書きを見つけるためのものです。**
    # 表が空のときは何も覚えません (抽象化していない設備では意味が無い)。
    attr_reader :unmapped

    def warn_unmapped? = @warn_unmapped && !@mapping.empty?

    # --- 解析 ---

    # シンボル名 (`$DM100`、`$DM100L`、割り付けた `$x0`) から
    #
    # **割り付け表を先に引きます。** 表に無い名前は今までどおり実デバイスとして
    # 読むので、表を書かない設備も表に無い名前も影響を受けません。
    def parse_symbol(sym)
      return nil unless sym

      mapped = parse_mapped(sym)
      return mapped if mapped

      parse(sym, prefix: "\\$").tap do |parsed|
        @unmapped << sym if parsed && warn_unmapped? && !@unmapped.include?(sym)
      end
    end

    # デバイス名 (`DM100`、$ なし) から
    def parse_name(name) = parse(name, prefix: "")

    # 割り付けた名前として読む (`$` 無し)。表に無ければ nil
    #
    # **コンソールが `dev x0` を読むのに使います。** `parse_symbol` を
    # 使わないのは、実デバイスの直書きを警告に数えてしまうためです
    # (コンソールから触った名前はプログラムが書いたものではない)。
    def parse_mapped_name(name) = name && parse_mapped("$#{name}")

    # デバイス族 (`$DM`、`$DML`、`$MR`)。アドレスを持たない形
    #
    # 添字を足して実行時にアドレスを決めるので、`z_offset` は 0 です。
    def parse_family(sym)
      return nil unless sym

      if (m = sym.match(family_pattern(word_names)))
        return entry(m[1], "0", m[2], bit: false, family: true)
      end
      return nil unless (m = sym.match(family_pattern(bit_names)))

      entry(m[1], "0", m[2], bit: m[2].to_s.empty?, family: true)
    end

    # 略記を正式名に直す。**plc_access は略記を知りません**
    def protocol_name(name) = device_set.normalize(name)

    # 幅サフィックスを ACCESS_* に直す
    #
    # 文字列 (T) だけは長さを持つため、同じワードに詰めて返します。
    # 既存の幅は 0-5 なので、6 以上なら文字列だと 1 比較で分かります。
    def access_from_suffix(suffix)
      suffix = suffix.to_s.upcase
      return ACCESS_SUFFIXES.fetch(suffix) unless suffix.start_with?("T")

      length = suffix[1..].to_i
      raise CodegenError, "文字列の桁数が大きすぎます (#{length} > #{MAX_STRING_FIELD})" if length > MAX_STRING_FIELD

      ACCESS_STR + length * ACCESS_STR_LENGTH_SCALE
    end

    def type_name(type) = device_set.find(type)&.name

    private

    # --- 割り付け表 ---

    # 割り付けた名前として読む。表に無ければ nil
    #
    # **幅サフィックスは名前を引いてから付けます。** `$x0L` は表の `x0L` を
    # 先に探し、無ければ `x0` を引いて `.L` を付けます。表に書いた名前が
    # そのまま勝つので、`x0L` という名前も作れます。
    def parse_mapped(sym)
      return nil if @mapping.empty?
      return nil unless sym.start_with?("$")

      name = sym[1..]
      return mapped_entry(@mapping[name], nil, sym) if @mapping.key?(name)

      m = name.match(/_?(L|D|U|S|F|T\d*)\z/i)
      return nil unless m

      base = name[0...m.begin(0)]
      return nil unless @mapping.key?(base)

      mapped_entry(@mapping[base], m[1], sym)
    end

    # 割り付け先を読む。使う側のサフィックスが表のものより優先する
    def mapped_entry(target, suffix, label)
      parsed = parse_name(target)
      raise CodegenError, mapping_error(label, target, "デバイスとして読めません") if parsed.nil?
      return parsed if suffix.nil? || suffix.empty?

      spec = "#{parsed[:device_name]}#{parsed[:address]}#{suffix}"
      begin
        parse_name(spec) ||
          raise(CodegenError, mapping_error(label, spec, "デバイスとして読めません"))
      rescue CodegenError => e
        raise CodegenError, mapping_error(label, target, e.message)
      end
    end

    def mapping_error(label, target, reason)
      "#{label} の割り付け先 #{target} は#{reason} (割り付け表)"
    end

    # **表そのものを転送前に検査します。** 使っていない名前の綴り誤りも、
    # 設定を読んだ時点で止まります。
    def validate_mapping!
      @mapping.each do |name, target|
        if parse_name(name) || parse_family("$#{name}")
          raise CodegenError,
                "割り付け表の #{name} は実デバイスの名前です。" \
                "割り付ける名前には実デバイスと重ならないものを使ってください"
        end
        mapped_entry(target, nil, "$#{name}")
      end
    end

    # --- 名前の並び ---
    #
    # **長い名前を先に並べます。** 選択肢は左から試されるので、`M` を先に
    # 置くと `MR100` が `M` + `R100` と読まれます。略記は正式名の後ろです。
    def word_names = @word_names ||= names_for(device_set.word_devices)
    def bit_names  = @bit_names  ||= names_for(device_set.bit_devices)

    def names_for(devices)
      (devices.map(&:name) + devices.flat_map(&:aliases)).sort_by { |n| [-n.size, n] }
    end

    # 16 進でアドレスを数えるデバイス
    #
    # **アドレスを貪欲に取ります** (`$B1F` は 0x1F)。`D` と `F` は数字でも
    # サフィックスでもあるためです。区切るなら `$B1_F` と書きます。
    def hex_names = @hex_names ||= names_for(device_set.devices.select { |d| d.numbering == :hex && d.supported? })
    def dec_names = @dec_names ||= (word_names + bit_names) - hex_names

    def parse(str, prefix:)
      return nil unless str

      if (m = str.match(/\A#{prefix}(#{alternation(word_names - hex_names)})(\d+)#{SUFFIX}\z/i))
        return entry(m[1], m[2], m[3], bit: false)
      end
      if (m = str.match(/\A#{prefix}(#{alternation(hex_names)})([0-9A-Fa-f]+)#{SUFFIX}\z/i))
        return entry(m[1], m[2], m[3], bit: m[3].to_s.empty?)
      end
      return nil unless (m = str.match(/\A#{prefix}(#{alternation(dec_names - word_names)})(\d+)#{SUFFIX}\z/i))

      entry(m[1], m[2], m[3], bit: m[3].to_s.empty?)
    end

    def alternation(names) = names.map { |n| Regexp.escape(n) }.join("|")

    def family_pattern(names) = /\A\$(#{alternation(names)})#{SUFFIX}\z/i

    def entry(name, addr_str, suffix, bit:, family: false)
      device_name = protocol_name(name.upcase)
      device = device_set.devices.find { |d| d.name == device_name }
      access_type = bit ? nil : access_from_suffix(suffix)
      check!(device, access_type)

      { device_type: device.type, address: addr_str,
        z_offset: family ? 0 : number_of(device, addr_str),
        device_name: device_name, bit: bit, access_type: access_type }
        .merge(family ? { family: true } : {})
    end

    # 実数と文字列を扱えるか
    def check!(device, access_type)
      return if access_type.nil?

      if access_type == ACCESS_F && !device.float?
        raise CodegenError, "#{device.name} は実数を扱えません"
      end
      return unless access_type >= ACCESS_STR && !device.word?

      raise CodegenError, "文字列を書けるのはワードデバイスだけです (#{device.name})"
    end

    # 表示上のアドレスを「デバイス番号」に直す
    #
    # **ワードデバイスは一致しますが、ビットデバイスは一致しません**
    # (`MR400` は 64、`B10` は 16)。番号空間では線形で、`MR415` の次は
    # `MR500` です。数え方はデバイスごとに違うので表から引きます。
    def number_of(device, addr_str)
      case device.numbering
      when :hex then addr_str.to_i(16)
      when :hexdec then addr_str.to_i / 100 * 16 + (addr_str.to_i % 100)
      else addr_str.to_i
      end
    end
  end
end
