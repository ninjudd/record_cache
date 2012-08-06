require 'test/unit'
require 'rubygems'
require 'shoulda'
require 'mocha'

$LOAD_PATH.unshift File.dirname(__FILE__) + "/../lib"
['deep_clonable', 'ordered_set', 'cache_version', 'model_set', 'memcache', 'deferrable'].each do |dir|
  $LOAD_PATH.unshift File.dirname(__FILE__) + "/../../#{dir}/lib"
end

require 'record_cache'

['lib/after_commit', 'lib/after_commit/active_record', 'lib/after_commit/connection_adapters', 'init'].each do |file|
  require File.dirname(__FILE__) + "/../../plugins/after_commit/#{file}"
end

class Test::Unit::TestCase
end

CACHE = Memcache.new(:servers => 'localhost')
ActiveRecord::Base.establish_connection(
  :adapter  => "postgresql",
  :host     => "localhost",
  :username => "postgres",
  :password => "",
  :database => "test"
)
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.connection.client_min_messages = 'panic'
