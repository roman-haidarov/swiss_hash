# frozen_string_literal: true

require_relative "swiss_hash/version"
require_relative "swiss_hash/swiss_hash.bundle"

module SwissHash
  class Hash
    alias_method :count, :size

    def merge!(other)
      other.each { |k, v| self[k] = v }
      self
    end
    alias_method :update, :merge!

    def to_h
      hash = {}
      each { |k, v| hash[k] = v }
      hash
    end

    def inspect
      s = stats
      "#<SwissHash::Hash size=#{s[:size]} capacity=#{s[:capacity]} load=#{(s[:load_factor] * 100).round(1)}%>"
    end
    alias_method :to_s, :inspect
  end
end
