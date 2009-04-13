require 'test/unit'
require 'rubygems'
require 'active_record'
require 'mocha'

['deep_clonable', 'cache_version', 'model_set', 'version', 'memcache', 'deferrable'].each do |dir|
  $:.unshift File.dirname(__FILE__) + "/../../#{dir}/lib"
end

['lib/after_commit', 'lib/after_commit/active_record', 'lib/after_commit/connection_adapters', 'init'].each do |file|
  require File.dirname(__FILE__) + "/../../after_commit/#{file}"
end

require File.dirname(__FILE__) + '/../lib/record_cache'
