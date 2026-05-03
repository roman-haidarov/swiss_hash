# frozen_string_literal: true

require_relative "swiss_hash/version"
require_relative "swiss_hash/swiss_hash"

module SwissHash
  class Hash
    include Enumerable

    def count(*args, &block)
      return size if args.empty? && !block

      each.count(*args, &block)
    end

    def dig(key, *rest)
      value = self[key]
      return value if rest.empty? || value.nil?

      value.dig(*rest)
    end

    def transform_keys!
      return enum_for(:transform_keys!) unless block_given?

      pairs = to_a
      clear
      pairs.each { |key, value| self[yield(key)] = value }
      self
    end

    def flatten(level = 1)
      to_a.flatten(level)
    end

    def ==(other)
      other = other.to_h if other.is_a?(self.class)
      to_h == other
    end

    def eql?(other)
      other = other.to_h if other.is_a?(self.class)
      to_h.eql?(other)
    end

    def hash
      to_h.hash
    end

    def inspect
      s = stats
      "#<SwissHash::Hash size=#{s[:size]} capacity=#{s[:capacity]} load=#{(s[:load_factor] * 100).round(1)}%>"
    end
    alias_method :to_s, :inspect
  end
end
