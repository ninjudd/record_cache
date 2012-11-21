require 'test/unit'
require 'rubygems'
require 'shoulda'
require 'mocha/setup'
require 'pp'

require 'record_cache'

class Test::Unit::TestCase
end

CACHE = Memcache.new(:servers => 'localhost')
ActiveRecord::Base.establish_connection(
  :adapter  => "postgresql",
  :host     => "localhost",
  :username => `whoami`.chomp,
  :password => "",
  :database => "test"
)
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.connection.client_min_messages = 'panic'
