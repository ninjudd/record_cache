require 'test/unit'
require 'rubygems'
require 'mocha'

$:.unshift(File.dirname(__FILE__) + '/../../deep_clonable/lib')
$:.unshift(File.dirname(__FILE__) + '/../../model_set/lib')
$:.unshift(File.dirname(__FILE__) + '/../../cache_version/lib')
$:.unshift(File.dirname(__FILE__) + '/../../memcache/lib')

require File.dirname(__FILE__) + '/../lib/record_cache'
