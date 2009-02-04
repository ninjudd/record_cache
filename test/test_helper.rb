require 'test/unit'
require 'rubygems'
require 'mocha'
require 'model_set'
require File.dirname(__FILE__) + '/../lib/record_cache'

class << Test::Unit::TestCase
  def test(name, &block)
    test_name = "test_#{name.gsub(/[\s\W]/,'_')}"
    raise ArgumentError, "#{test_name} is already defined" if self.instance_methods.include? test_name
    define_method test_name, &block
  end
end
