require 'rake'
require 'rake/testtask'
require 'rake/rdoctask'

begin
  require 'jeweler'
  Jeweler::Tasks.new do |s|
    s.name = "record_cache"
    s.summary = %Q{Active Record caching and indexing in memcache. An alternative to cache_fu}
    s.email = "code@justinbalthrop.com"
    s.homepage = "http://github.com/ninjudd/record_cache"
    s.description = "Active Record caching and indexing in memcache"
    s.authors = ["Justin Balthrop"]
    s.add_dependency('after_commit', '>= 1.0.0')
    s.add_dependency('deferrable', '>= 0.1.0')
    s.add_dependency('memcache', '>= 1.0.0')
    s.add_dependency('cache_version', '>= 0.9.4')
    s.add_dependency('activerecord', '>= 2.0.0')
  end
rescue LoadError
  puts "Jeweler not available. Install it with: sudo gem install technicalpickles-jeweler -s http://gems.github.com"
end

Rake::TestTask.new do |t|
  t.libs << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.verbose = false
end

Rake::RDocTask.new do |rdoc|
  rdoc.rdoc_dir = 'rdoc'
  rdoc.title    = 'record_cache'
  rdoc.options << '--line-numbers' << '--inline-source'
  rdoc.rdoc_files.include('README*')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

begin
  require 'rcov/rcovtask'
  Rcov::RcovTask.new do |t|
    t.libs << 'test'
    t.test_files = FileList['test/**/*_test.rb']
    t.verbose = true
  end
rescue LoadError
end

task :default => :test
