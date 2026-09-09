# frozen_string_literal: true

require_relative "dialect"
require_relative "kvs_generator"

module FaRuby
  # 生成した ST の型を突き合わせる
  #
  # **綴り方が挟んだ変換が行き渡っているかを見ます** (tools/melsec_types.rb)。
  # 型の判定は綴り方と同じものを使うので、片方だけ賢くなることがありません。
  #
  # 変換にかけるまで分からないと 1 往復ごとに 1 件しか潰せないので、
  # ここでまとめて出します。
  class MelsecTypecheck
    Finding = Struct.new(:file, :line, :text, :reason)

    def initialize(layout: nil)
      @dialect = MelsecDialect.new
      @generator = KvsGenerator.new(layout: layout || MemoryLayout.default, dialect: @dialect)
      @files = @generator.generate
      @types = @dialect.types
    end

    def findings
      @files.flat_map do |name, content|
        next [] unless name.end_with?(".st")

        content.split("\n").each_with_index.filter_map { |line, i| check(name, i + 1, line) }
      end
    end

    private

    attr_reader :types

    def check(file, number, line)
      code = line.split("(*").first.to_s.strip
      return if code.empty?

      mixed = mixed_expression(code)
      return Finding.new(file, number, line.strip, mixed) if mixed

      operation = types.split_operation(code)
      return if operation.nil?

      operator, lhs, rhs = operation
      left = types.type_of(lhs)
      right = types.type_of(rhs)
      return if left.nil? || right.nil? || left == right

      Finding.new(file, number, line.strip, "#{operator}: #{left} と #{right}")
    end

    # **1 つの式の中で型が混ざっているもの。** 両辺が合っていても、
    # 式の中で 16 ビットと 32 ビットを足していれば通りません
    def mixed_expression(code)
      operation = types.split_operation(code)
      return nil if operation.nil?

      _operator, *sides = operation
      sides.first(2).each do |side|
        found = types.types_in(side)
        return "式の中で混ざっています: #{found.join(' と ')}" if found.size > 1
      end
      nil
    end
  end
end
