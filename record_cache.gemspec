# Generated by jeweler
# DO NOT EDIT THIS FILE DIRECTLY
# Instead, edit Jeweler::Tasks in Rakefile, and run 'rake gemspec'
# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{record_cache}
  s.version = "0.9.6"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Justin Balthrop", "Matt Knopp", "Philippe Le Rohellec"]
  s.date = %q{2011-12-09}
  s.description = %q{Active Record caching and indexing in memcache}
  s.email = %q{code@justinbalthrop.com}
  s.extra_rdoc_files = [
    "LICENSE",
    "README.rdoc"
  ]
  s.files = [
    "LICENSE",
    "README.rdoc",
    "Rakefile",
    "VERSION",
    "lib/record_cache.rb",
    "lib/record_cache/index.rb",
    "lib/record_cache/scope.rb",
    "lib/record_cache/set.rb",
    "record_cache.gemspec",
    "test/record_cache_test.rb",
    "test/test_helper.rb"
  ]
  s.homepage = %q{http://github.com/yammer/record_cache}
  s.require_paths = ["lib"]
  s.rubygems_version = %q{1.5.3}
  s.summary = %q{Active Record caching and indexing in memcache. An alternative to cache_fu}

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end

