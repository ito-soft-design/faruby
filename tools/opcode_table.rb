# frozen_string_literal: true

# オペコード定義表 (唯一の情報源)
#
# ここに書いた命令定義から以下すべてが導かれます。
#   - plc/keyence/vm_core.kvs      (KvsEmitter が KV スクリプトを生成)
#   - simulator/kv_vm_simulator.rb (SimVm が同じ定義を実行)
#   - tools/disasm.rb              (MRUBY_OPCODES を参照)
#
# 命令の追加・変更はこのファイルだけを直し、`rake vm_core` で再生成します。
#
# ## 命令本体の書き方
#
# body は「バックエンド」を1つ受け取ります。バックエンドは2種類あり、
# 同じ記述をそれぞれ別の方法で解釈します。
#
#   KvsEmitter (tools/kvs_generator.rb) : KV スクリプトの文字列を組み立てる
#   SimVm      (simulator/sim_vm.rb)    : EM メモリ上で実際に実行する
#
# したがって body には **PLC 機種固有の名前を書かないでください**。
# デバイス名・インデックスレジスタ・型サフィックスはバックエンドの管轄です。
#
#   悪い例: vm.line "EM16 = EM8"
#   良い例: vm.set_reg(:a, vm.sign_extend(vm.operand(:b), 8))
#
# test_kvs_generator.rb がこの規約を検証します。
#
# ## バックエンドが提供する操作
#
# 値を返すもの (中身は KV では文字列、シミュレータでは整数):
#   operand(:a/:b/:c)      オペランドの値
#   reg(:a) / reg_next(:a) R[a] / R[a+1]
#   pool(:b)               Pool[b]
#   const(n)               即値
#   sign_extend(v, bits)   符号拡張
#   compose32(hi, lo)      上位/下位ワードから32ビット値
#   negate(v)              符号反転
#   binop(:add/:sub/:mul, lhs, rhs)
#   cmp(:eq/:ne, lhs, rhs) 条件
#
# 動作するもの:
#   set_reg(:a, value)
#   set_reg_bool(:a, :lt, lhs, rhs)      R[a] = (lhs < rhs) ? 1 : 0
#   set_reg_div(:a, lhs, rhs, code)      0除算はエラー停止
#   load_global_into_reg(:a, :b)         R[a] = global[symbols[b]]
#   store_reg_into_global(:b, :a)        global[symbols[b]] = R[a]
#   normalize_signed16(:b)               オペランドを符号付き16ビットとして解釈
#   jump_relative(:b)                    PC += オペランド
#   vm_finish / vm_error(code)
#   if_(cond) { ... }
#   note(text)                           生成コードへのコメント

module FaRuby
  module OpcodeTable
    # mruby 3.x の全オペコード: コード => [名前, 命令形式]
    # 逆アセンブラは未実装の命令も表示するため、実装済みの命令より広い集合です。
    MRUBY_OPCODES = {
      0x00 => [:OP_NOP,        :Z],
      0x01 => [:OP_MOVE,       :BB],
      0x02 => [:OP_LOADL,      :BB],
      0x03 => [:OP_LOADI,      :BB],
      0x04 => [:OP_LOADINEG,   :BB],
      0x05 => [:OP_LOADI__1,   :B],
      0x06 => [:OP_LOADI_0,    :B],
      0x07 => [:OP_LOADI_1,    :B],
      0x08 => [:OP_LOADI_2,    :B],
      0x09 => [:OP_LOADI_3,    :B],
      0x0A => [:OP_LOADI_4,    :B],
      0x0B => [:OP_LOADI_5,    :B],
      0x0C => [:OP_LOADI_6,    :B],
      0x0D => [:OP_LOADI_7,    :B],
      0x0E => [:OP_LOADI16,    :BS],
      0x0F => [:OP_LOADI32,    :BSS],
      0x10 => [:OP_LOADSYM,    :BB],
      0x11 => [:OP_LOADNIL,    :B],
      0x12 => [:OP_LOADSELF,   :B],
      0x13 => [:OP_LOADT,      :B],
      0x14 => [:OP_LOADF,      :B],
      0x15 => [:OP_GETGV,      :BB],
      0x16 => [:OP_SETGV,      :BB],
      0x17 => [:OP_GETSV,      :BB],
      0x18 => [:OP_SETSV,      :BB],
      0x19 => [:OP_GETIV,      :BB],
      0x1A => [:OP_SETIV,      :BB],
      0x1B => [:OP_GETCV,      :BB],
      0x1C => [:OP_SETCV,      :BB],
      0x1D => [:OP_GETCONST,   :BB],
      0x1E => [:OP_SETCONST,   :BB],
      0x1F => [:OP_GETMCNST,   :BB],
      0x20 => [:OP_SETMCNST,   :BB],
      0x21 => [:OP_GETUPVAR,   :BBB],
      0x22 => [:OP_SETUPVAR,   :BBB],
      0x23 => [:OP_GETIDX,     :B],
      0x24 => [:OP_SETIDX,     :B],
      0x25 => [:OP_JMP,        :S],
      0x26 => [:OP_JMPIF,      :BS],
      0x27 => [:OP_JMPNOT,     :BS],
      0x28 => [:OP_JMPNIL,     :BS],
      0x29 => [:OP_JMPUW,      :S],
      0x2A => [:OP_EXCEPT,     :B],
      0x2B => [:OP_RESCUE,     :BB],
      0x2C => [:OP_RAISEIF,    :B],
      0x2D => [:OP_SSEND,      :BBB],
      0x2E => [:OP_SSENDB,     :BBB],
      0x2F => [:OP_SEND,       :BBB],
      0x30 => [:OP_SENDB,      :BBB],
      0x31 => [:OP_CALL,       :Z],
      0x32 => [:OP_SUPER,      :BB],
      0x33 => [:OP_ARGARY,     :BS],
      0x34 => [:OP_ENTER,      :W],
      0x35 => [:OP_KEY_P,      :BB],
      0x36 => [:OP_KEYEND,     :Z],
      0x37 => [:OP_KARG,       :BB],
      0x38 => [:OP_RETURN,     :B],
      0x39 => [:OP_RETURN_BLK, :B],
      0x3A => [:OP_BREAK,      :B],
      0x3B => [:OP_BLKPUSH,    :BS],
      0x3C => [:OP_ADD,        :B],
      0x3D => [:OP_ADDI,       :BB],
      0x3E => [:OP_SUB,        :B],
      0x3F => [:OP_SUBI,       :BB],
      0x40 => [:OP_MUL,        :B],
      0x41 => [:OP_DIV,        :B],
      0x42 => [:OP_EQ,         :B],
      0x43 => [:OP_LT,         :B],
      0x44 => [:OP_LE,         :B],
      0x45 => [:OP_GT,         :B],
      0x46 => [:OP_GE,         :B],
      0x47 => [:OP_ARRAY,      :BB],
      0x48 => [:OP_ARRAY2,     :BBB],
      0x49 => [:OP_ARYCAT,     :B],
      0x4A => [:OP_ARYPUSH,    :BB],
      0x4B => [:OP_ARYSPLAT,   :B],
      0x4C => [:OP_AREF,       :BBB],
      0x4D => [:OP_ASET,       :BBB],
      0x4E => [:OP_APOST,      :BBB],
      0x4F => [:OP_INTERN,     :B],
      0x50 => [:OP_SYMBOL,     :BB],
      0x51 => [:OP_STRING,     :BB],
      0x52 => [:OP_STRCAT,     :B],
      0x53 => [:OP_HASH,       :BB],
      0x54 => [:OP_HASHADD,    :BB],
      0x55 => [:OP_HASHCAT,    :B],
      0x56 => [:OP_LAMBDA,     :BB],
      0x57 => [:OP_BLOCK,      :BB],
      0x58 => [:OP_METHOD,     :BB],
      0x59 => [:OP_RANGE_INC,  :B],
      0x5A => [:OP_RANGE_EXC,  :B],
      0x5B => [:OP_OCLASS,     :B],
      0x5C => [:OP_CLASS,      :BB],
      0x5D => [:OP_MODULE,     :BB],
      0x5E => [:OP_EXEC,       :BB],
      0x5F => [:OP_DEF,        :BB],
      0x60 => [:OP_ALIAS,      :BB],
      0x61 => [:OP_UNDEF,      :B],
      0x62 => [:OP_SCLASS,     :B],
      0x63 => [:OP_TCLASS,     :B],
      0x64 => [:OP_DEBUG,      :BBB],
      0x65 => [:OP_ERR,        :B],
      0x66 => [:OP_EXT1,       :Z],
      0x67 => [:OP_EXT2,       :Z],
      0x68 => [:OP_EXT3,       :Z],
      0x69 => [:OP_STOP,       :Z],
    }.freeze

    # 命令形式 => オペランドのバイト数の並び (1=バイト, 2=16ビットBE, 3=24ビット)
    FORMAT_OPERANDS = {
      Z: [], B: [1], BB: [1, 1], BBB: [1, 1, 1],
      S: [2], BS: [1, 2], BSS: [1, 2, 2], W: [3],
    }.freeze

    # 命令形式 => オペランド部の総バイト数
    FORMAT_SIZES = FORMAT_OPERANDS.transform_values(&:sum).freeze
  end

  # 1 命令の定義。name / format は MRUBY_OPCODES から引くので取り違えが起きない。
  class OpcodeDef
    attr_reader :code, :name, :format, :summary, :body

    def initialize(code, summary, &body)
      info = OpcodeTable::MRUBY_OPCODES[code]
      raise ArgumentError, format("未知のオペコード 0x%02X", code) unless info

      @code = code
      @name, @format = info
      @summary = summary
      @body = body
    end

    def operand_sizes
      OpcodeTable::FORMAT_OPERANDS.fetch(format)
    end

    # 生成コードの見出しコメント (例: "OP_MOVE (BB): R[a] = R[b]")
    def header_comment
      "#{name} (#{format}): #{summary}"
    end
  end

  module OpcodeTable
    module_function

    # 実装済み命令 (コード順)
    def all
      @all ||= build.sort_by(&:code).freeze
    end

    def codes
      all.map(&:code)
    end

    # コード => 定義
    def lookup
      @lookup ||= all.to_h { |op| [op.code, op] }.freeze
    end

    def build
      defs = []

      defs << OpcodeDef.new(0x00, "何もしない") { |_vm| }

      defs << OpcodeDef.new(0x01, "R[a] = R[b]") do |vm|
        vm.move_reg(:a, :b)
      end

      defs << OpcodeDef.new(0x02, "R[a] = Pool[b]") do |vm|
        vm.load_pool(:a, :b)
      end

      # b は符号なし (0-255)。mruby の vm.c は SET_FIXNUM_VALUE(regs[a], b) で、
      # 符号拡張しない。負値は OP_LOADINEG が受け持つ。
      # 符号付きとして扱うと 128 以上が負になり、`while i < 200` が回らない。
      defs << OpcodeDef.new(0x03, "R[a] = b (符号なし)") do |vm|
        vm.set_reg_int(:a, vm.operand(:b))
      end

      defs << OpcodeDef.new(0x04, "R[a] = -b") do |vm|
        vm.set_reg_int(:a, vm.negate(vm.operand(:b)))
      end

      defs << OpcodeDef.new(0x05, "R[a] = -1") do |vm|
        vm.set_reg_int(:a, vm.const(-1))
      end

      # OP_LOADI_0 ~ OP_LOADI_7
      (0..7).each do |n|
        defs << OpcodeDef.new(0x06 + n, "R[a] = #{n}") do |vm|
          vm.set_reg_int(:a, vm.const(n))
        end
      end

      defs << OpcodeDef.new(0x0E, "R[a] = signed16(b)") do |vm|
        vm.set_reg_int(:a, vm.sign_extend(vm.operand(:b), 16))
      end

      defs << OpcodeDef.new(0x0F, "R[a] = (b<<16)+c") do |vm|
        vm.set_reg_int(:a, vm.compose32(vm.operand(:b), vm.operand(:c)))
      end

      defs << OpcodeDef.new(0x11, "R[a] = nil") do |vm|
        vm.set_reg_special(:a, VmConstants::TT_NIL)
      end

      # トップレベルの self は main。オブジェクトは未実装だが、
      # 真偽判定では真になる必要があるためタグだけ付けておく
      defs << OpcodeDef.new(0x12, "R[a] = self (main)") do |vm|
        vm.set_reg_special(:a, VmConstants::TT_OBJECT)
      end

      defs << OpcodeDef.new(0x13, "R[a] = true") do |vm|
        vm.set_reg_special(:a, VmConstants::TT_TRUE)
      end

      defs << OpcodeDef.new(0x14, "R[a] = false") do |vm|
        vm.set_reg_special(:a, VmConstants::TT_FALSE)
      end

      defs << OpcodeDef.new(0x15, "R[a] = global[symbols[b]]") do |vm|
        vm.load_global_into_reg(:a, :b)
      end

      defs << OpcodeDef.new(0x16, "global[symbols[b]] = R[a]") do |vm|
        vm.store_reg_into_global(:b, :a)
      end

      defs << OpcodeDef.new(0x25, "PC += signed16(a)") do |vm|
        vm.normalize_signed16(:a)
        vm.jump_relative(:a)
      end

      # 真偽判定は型タグで行う。Ruby で偽なのは nil と false だけで、
      # 0 も真になる (値で判定していたころは 0 が偽になっていた)
      defs << OpcodeDef.new(0x26, "if R[a] が真 then PC += signed16(b)") do |vm|
        vm.normalize_signed16(:b)
        vm.if_truthy(:a) { vm.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x27, "if R[a] が偽 (nil/false) then PC += signed16(b)") do |vm|
        vm.normalize_signed16(:b)
        vm.if_falsy(:a) { vm.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x28, "if R[a] が nil then PC += signed16(b)") do |vm|
        vm.normalize_signed16(:b)
        vm.if_nil(:a) { vm.jump_relative(:b) }
      end

      defs << OpcodeDef.new(0x38, "トップレベルでは VM 停止") do |vm|
        vm.vm_finish
      end

      # 二項算術: R[a] = R[a] <op> R[a+1]
      #
      # 両オペランドの型で振り分ける。実数が絡めば実数演算になり、
      # 整数どうしなら整数演算のまま (32ビット整数は単精度に収まらないため)。
      { 0x3C => :add, 0x3E => :sub, 0x40 => :mul }.each do |code, op|
        defs << OpcodeDef.new(code, "R[a] = R[a] #{OPERATOR_TEXT[op]} R[a+1]") do |vm|
          vm.set_reg_arith(:a, op)
        end
      end

      # 即値算術: R[a] = R[a] <op> b (b は常に整数)
      { 0x3D => :add, 0x3F => :sub }.each do |code, op|
        defs << OpcodeDef.new(code, "R[a] = R[a] #{OPERATOR_TEXT[op]} b") do |vm|
          vm.set_reg_arith(:a, op, immediate: :b)
        end
      end

      defs << OpcodeDef.new(0x41, "R[a] = R[a] / R[a+1]") do |vm|
        vm.set_reg_div(:a, DIVIDE_BY_ZERO_ERROR)
      end

      # 等値比較は型も見る (nil == false は偽、1 == 1.0 は真)
      defs << OpcodeDef.new(0x42, "R[a] = (R[a] == R[a+1]) ? true : false") do |vm|
        vm.set_reg_eq(:a)
      end

      # 大小比較: 数値は型が違っても値で比べる
      { 0x43 => :lt, 0x44 => :le, 0x45 => :gt, 0x46 => :ge }.each do |code, op|
        defs << OpcodeDef.new(code, "R[a] = (R[a] #{OPERATOR_TEXT[op]} R[a+1]) ? true : false") do |vm|
          vm.set_reg_cmp(:a, op)
        end
      end

      defs << OpcodeDef.new(0x69, "VM 停止") do |vm|
        vm.vm_finish
      end

      defs
    end

    # 0 除算のエラーコード
    DIVIDE_BY_ZERO_ERROR = 1

    # 見出しコメントに使う演算子の表記
    OPERATOR_TEXT = {
      add: "+", sub: "-", mul: "*", div: "/",
      eq: "=", ne: "<>", lt: "<", le: "<=", gt: ">", ge: ">=",
    }.freeze
  end
end
