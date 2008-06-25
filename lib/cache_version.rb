class CacheVersion < ActiveRecord::Base
  
  after_save    :invalidate_cache
  after_destroy :invalidate_cache
  
  def invalidate_cache
    CACHE.delete(self.class.cache_key(key))
  end
  
  def self.get(key)
    lookup(key).version
  end
  
  def self.lookup(key)
    key = key.to_s
    @version_by_key ||= {}    
    @version_by_key[key] ||= CACHE.get_or_set(cache_key(key)) do    
      find_by_key(key) || create!(:key => key)
    end
  end
  
  def self.clear_cache
    @version_by_key = {}
  end
  
  def self.increment(key)
    cv = lookup(key)
    cv.version += 1
    cv.save
    cv.version
  end
    
  def self.cache_key(key)
    "cv:#{key}"
  end
      
end

class CacheVersionMigration < ActiveRecord::Migration
  def self.up
    create_table :cache_versions do |t|
      t.column :key, :string
      t.column :version, :integer, :default => 0
    end

    add_index :cache_versions, :key, :unique => true
  end

  def self.down
    drop_table :cache_versions
  end
end