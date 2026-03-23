# frozen_string_literal: true

require_relative "lib/swiss_hash/version"

Gem::Specification.new do |spec|
  spec.name     = "swiss_hash"
  spec.version  = SwissHash::VERSION
  spec.authors  = ["Roman Haidarov"]
  spec.email    = ["roman.haidarov@hey.com"]

  spec.summary  = "Swiss Table hash map as a Ruby C extension"
  spec.homepage = "https://github.com/roman-haidarov/swiss_hash"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rb,c,h}",
    "LICENSE.txt",
    "README.md"
  ]

  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/swiss_hash/extconf.rb"]

  spec.add_development_dependency "rake-compiler", "~> 1.0"
end
