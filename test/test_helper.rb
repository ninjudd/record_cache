require 'test/unit'
require 'rubygems'
require 'shoulda'
require 'mocha'

require 'active_record'

$LOAD_PATH.unshift(File.dirname(__FILE__) + "/../lib")
['deep_clonable', 'cache_version', 'model_set', 'version', 'memcache', 'deferrable'].each do |dir|
  $LOAD_PATH.unshift File.dirname(__FILE__) + "/../../#{dir}/lib"
end

['lib/after_commit', 'lib/after_commit/active_record', 'lib/after_commit/connection_adapters', 'init'].each do |file|
  require File.dirname(__FILE__) + "/../../after_commit/#{file}"
end

require 'record_cache'

class Test::Unit::TestCase
end

CACHE = MemCache.new(
  :ttl=>1800,
  :compression=>false,
  :readonly=>false,
  :debug=>false,
  :c_threshold=>10000,
  :urlencode=>false
)
ActiveRecord::Base.establish_connection(
  :adapter  => "postgresql",
  :host     => "localhost",
  :username => "postgres",
  :password => "",
  :database => "record_cache_test"
)
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.connection.client_min_messages = 'panic'
