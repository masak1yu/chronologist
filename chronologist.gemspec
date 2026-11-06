# lib を require しないのは gem build 時に余計な定数を読ませないため
Gem::Specification.new do |s|
  s.name = "chronologist"
  s.version = File.read("lib/chronologist.rb")[/VERSION = "(.+?)"/, 1]
  s.summary = "Rails ログのタイムゾーン・書式・トレース相関を一箇所で統一する"
  s.authors = ["masak1yu"]
  s.license = "MIT"
  s.required_ruby_version = ">= 3.1"
  s.files = Dir["lib/**/*.rb", "README.md"]
end
