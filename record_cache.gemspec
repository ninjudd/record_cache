lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |gem|
  gem.name          = "record_cache"
  gem.version       = IO.read('VERSION')
  gem.authors       = ["Justin Balthrop"]
  gem.email         = ["git@justinbalthrop.com"]
  gem.description   = %q{Active Record caching and indexing in memcache.}
  gem.summary       = gem.description
  gem.homepage      = "https://github.com/ninjudd/record_cache"
  gem.license       = 'MIT'

  gem.add_development_dependency 'shoulda', '3.0.1'
  gem.add_development_dependency 'mocha'
  gem.add_development_dependency 'rsolr'
  gem.add_development_dependency 'json'
  gem.add_development_dependency 'rake'
  gem.add_development_dependency 'activerecord-postgresql-adapter'

  gem.add_dependency 'after_commit',  '>= 1.0.0'
  gem.add_dependency 'deferrable',    '>= 0.1.0'
  gem.add_dependency 'memcache',      '>= 1.0.0'
  gem.add_dependency 'cache_version', '>= 0.9.4'
  gem.add_dependency 'activerecord',  '~> 2.3.9'

  gem.files         = `git ls-files`.split($/)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]
end
