= RecordCache

RecordCache is a simple yet powerful extension to ActiveRecord that caches indexes
and ActiveRecord models using MemCache.

== INSTALL:

  sudo gem install record_cache

Also, you need to create a migration to make the cache_versions table. See examples/sample_migration.rb

== USAGE:

  class Foo < ActiveRecord
    record_cache :by => :id
    record_cache :id, :by => :owner_id
  end

  # These will use the cache now.
  Foo.find(1)
  Foo.find_by_id(2)
  Foo.find_all_by_owner_id(3)

Invalidation is handled for you using after_save and after_destroy filters.

== LICENSE:

(The MIT License)

Copyright (c) 2008 FIX

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
